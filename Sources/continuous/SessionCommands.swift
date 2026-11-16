import Foundation
import Network
import ContinuousCore

extension Commands {

    // MARK: - listen

    static func listen(_ args: Args) throws {
        let identity = try Identity.loadOrCreate()
        var config = try Config.load()
        if let p = try args.uint16("port") { config.port = p }
        if args.bool("no-bonjour") { config.bonjourEnabled = false }
        if args.bool("allow-public") { config.requireLocalNetwork = false }

        let directory = try PairingDirectory.load()
        directory.allowRebind = args.bool("rebind")
        guard !directory.snapshot.pairings.isEmpty else { throw ContinuousError.notPaired }

        if !config.requireLocalNetwork {
            warn("--allow-public: this Mac will accept links from any address, not just your LAN")
        }
        if directory.allowRebind {
            warn("--rebind: a pairing may be re-bound to a different Mac on the next connection")
        }

        directory.onBind = { pairing in
            ok("pairing '\(pairing.label)' is now pinned to \(pairing.peerDeviceID?.short ?? "?") (\(pairing.peerName ?? "unnamed"))")
        }

        let options = LinkListener.Options(
            port: config.port,
            requireLocalNetwork: config.requireLocalNetwork,
            bonjourName: config.bonjourEnabled ? identity.deviceName : nil)

        let listener = LinkListener(identity: identity,
                                    localRole: .client,
                                    options: options,
                                    keys: directory.allKeys,
                                    resolvePSK: { [weak directory] keyID in directory?.psk(forKeyID: keyID) },
                                    authorizePeer: { [weak directory] id, keyID in
                                        directory?.authorize(deviceID: id, keyID: keyID) ?? false
                                    })

        var heartbeats: [ObjectIdentifier: Heartbeat] = [:]
        let lock = NSLock()

        listener.onListening = { port in
            ok("listening on port \(Style.bold(String(port)))  ·  \(identity.deviceName)  ·  \(identity.deviceID.short)")
            if config.bonjourEnabled {
                info("advertising over Bonjour as \"\(identity.deviceName)\"")
            }
            info("waiting for the other Mac — Ctrl-C to stop")
            out()
            for (name, addr) in LocalInterfaces.list() {
                out(Style.dim("    reachable at \(addr.split(separator: " ")[0]):\(port)   (\(name))"))
            }
            out()
        }

        listener.onRejected = { endpoint, reason in
            warn("refused \(endpoint): \(reason)")
        }

        listener.onLinkReady = { link, peer in
            directory.note(peer: peer)
            ok("link up  ←  \(Style.bold(peer.name))  [\(peer.deviceID.short)]  \(peer.endpoint)")
            info("\(peer.tlsDescription)  ·  key \(String(Crypto.hex(peer.keyID).prefix(8)))  ·  role \(peer.role)")

            let heartbeat = Heartbeat(link: link)
            lock.lock(); heartbeats[ObjectIdentifier(link)] = heartbeat; lock.unlock()
            link.onMessage = { message in
                heartbeat.handle(message)
                describeInbound(message)
            }
        }

        listener.onLinkClosed = { peer, error in
            lock.lock(); heartbeats.removeAll(); lock.unlock()
            if let error {
                bad("link down: \(error.localizedDescription)")
            } else if let peer {
                info("link closed  ·  \(peer.name)")
            }
            info("waiting for the other Mac — Ctrl-C to stop")
        }

        listener.onFailure = { error in
            bad("listener failed: \(error.localizedDescription)")
            if case NWError.posix(.EADDRINUSE) = error {
                out(Style.dim("  Port \(config.port) is already taken. Another `continuous listen` may be running,"))
                out(Style.dim("  or pick a different one with --port."))
            }
            exit(1)
        }

        try listener.start()
        Runtime.installSignalHandlers()
        while !Runtime.interrupted { Thread.sleep(forTimeInterval: 0.1) }
        out()
        info("shutting down")
        listener.stop()
    }

    // MARK: - connect

    static func connect(_ args: Args) throws {
        let identity = try Identity.loadOrCreate()
        var config = try Config.load()
        if let p = try args.uint16("port") { config.port = p }

        let directory = try PairingDirectory.load()
        let store = directory.snapshot
        guard !store.pairings.isEmpty else { throw ContinuousError.notPaired }

        let target = try args.require(0, "HOST|NAME")

        // Which shared key do we dial with?
        let pairing: Pairing
        if let needle = args.string("pair") {
            pairing = store.pairings[try store.index(matching: needle)]
        } else if store.pairings.count == 1 {
            pairing = store.pairings[0]
        } else {
            throw ContinuousError.invalidArgument(
                "this Mac has \(store.pairings.count) pairings — choose one with --pair <label>:\n    "
                + store.pairings.map(\.label).joined(separator: "\n    "))
        }

        let endpoint = try resolveTarget(target, defaultPort: config.port)
        info("dialling \(NetworkAddress.describe(endpoint)) with pairing '\(pairing.label)'")

        let link = LinkConnector.connect(to: endpoint,
                                         psk: pairing.psk,
                                         identity: identity,
                                         localRole: .host)
        let heartbeat = Heartbeat(link: link)
        let finished = NSLock()
        var done = false
        var failure: Error?

        link.onReady = { peer in
            directory.note(peer: peer)
            ok("link up  →  \(Style.bold(peer.name))  [\(peer.deviceID.short)]  \(peer.endpoint)")
            info("\(peer.tlsDescription)  ·  key \(String(Crypto.hex(peer.keyID).prefix(8)))  ·  role \(peer.role)")
            out()
            heartbeat.start()
        }

        var printed = 0
        heartbeat.onSample = { ms, stats in
            printed += 1
            // Print every sample for the first few, then settle into a periodic summary so a
            // long-running link does not spam the terminal.
            if printed <= 5 || printed % 15 == 0 {
                out(String(format: "  rtt %6.2f ms   \(Style.dim(stats.summary))", ms))
            }
        }
        heartbeat.onTimeout = { seq in warn("heartbeat \(seq) lost") }

        link.onMessage = { message in heartbeat.handle(message) }

        link.onClose = { error in
            finished.lock(); done = true; failure = error; finished.unlock()
        }

        link.start()
        Runtime.installSignalHandlers()

        let duration = try args.double("duration")
        let deadline = duration.map { Date().addingTimeInterval($0) }

        while true {
            finished.lock(); let isDone = done; finished.unlock()
            if isDone || Runtime.interrupted { break }
            if let deadline, Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        heartbeat.stop()
        let stats = heartbeat.snapshot
        if stats.samples > 0 {
            out()
            ok("latency over \(stats.samples) samples: \(stats.summary)")
        }

        finished.lock(); let err = failure; finished.unlock()
        if let err {
            bad(err.localizedDescription)
            throw ExitSilently(code: 1)
        }
        link.close(reason: "user stopped")
        out()
        info("disconnected")
    }

    /// A target may be an IP, a host:port, or a Bonjour service name advertised by the other Mac.
    private static func resolveTarget(_ target: String, defaultPort: UInt16) throws -> NWEndpoint {
        let looksLikeAddress = target.contains(".") || target.contains(":") || target.allSatisfy { $0.isNumber }
        if !looksLikeAddress {
            info("looking up \"\(target)\" over Bonjour…")
            let peers = Discovery.scan(duration: 3)
            if let match = peers.first(where: { $0.serviceName.lowercased() == target.lowercased() })
                ?? peers.first(where: { $0.serviceName.lowercased().contains(target.lowercased()) }) {
                return match.endpoint
            }
            warn("no Bonjour service named \"\(target)\" — trying it as a hostname")
        }
        return try LinkConnector.parseEndpoint(target, defaultPort: defaultPort)
    }

    /// Milestone 1 has no input pipeline yet, so inbound traffic is simply reported.
    private static func describeInbound(_ message: Message) {
        switch message {
        case .ping, .pong:
            break
        case let .mouseMove(x, y, _, _):
            Log.debug("mouse → (\(x), \(y))")
        case let .keyEvent(code, down, _, _):
            Log.debug("key \(down ? "down" : "up  ") \(code)")
        default:
            Log.debug("received \(message.type)")
        }
    }
}

struct ExitSilently: Error {
    let code: Int32
}
