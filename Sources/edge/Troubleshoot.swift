import Foundation
import Network
import EdgeCore

extension Commands {

    /// Works out why two Macs are not talking, and says so in plain terms.
    ///
    /// Written after a report of "pairing fails" that was nothing to do with pairing: the
    /// other Mac was reachable but its port was closed, and the network between them was
    /// averaging a quarter of a second of round trip. Neither fact was visible anywhere in
    /// the app, and both are decisive.
    static func troubleshoot(_ args: Args) throws {
        let config = try Config.load()
        let store = try SecretStore.load()
        var problems: [String] = []

        out(Style.bold("Pairings on this Mac"))
        if store.pairings.isEmpty {
            bad("none — nothing to connect to")
            problems.append("no pairing")
        }
        for pairing in store.pairings {
            out("  \(Style.bold(pairing.label))")
            // The key id is derived from the shared secret, so it is identical on both Macs
            // when and only when the pairing worked. It is the one check a person can make
            // without the two machines being able to talk.
            out("    key  \(Style.cyan(String(pairing.keyIDHex.prefix(8))))   "
                + Style.dim("← must be identical on the other Mac"))
            out("    \(pairing.statusText)")
            if let manual = pairing.manualEndpoint { out("    address set to \(manual)") }
            else if let last = pairing.lastEndpoint { out("    last seen at \(last)") }
        }
        out()

        out(Style.bold("This Mac"))
        for (name, addr) in LocalInterfaces.list() {
            out("  \(name)  \(addr.split(separator: " ")[0])")
        }
        if let running = RuntimeState.all.first(where: \.isLive) {
            ok("a session is running (\(running.role.displayName), pid \(running.pid))")
        } else {
            info("no session running here")
        }
        out()

        // The firewall is the commonest reason a listening Mac cannot be reached, and it says
        // nothing when it blocks: the port simply refuses, exactly as if nothing were running.
        out(Style.bold("Firewall"))
        let firewall = FirewallCheck.state()
        switch firewall {
        case .off:
            ok("off — incoming connections are not blocked")
        case .on(let blocked):
            if blocked {
                bad("on, and Edge is not allowed to accept incoming connections")
                problems.append("firewall blocking")
                FirewallCheck.explainHowToAllow()
            } else {
                ok("on, and Edge is allowed through")
            }
        case .unknown:
            info("could not be read")
        }
        out()

        out(Style.bold("The other Mac"))
        let targets = store.pairings.compactMap { pairing -> (String, String)? in
            guard let address = pairing.manualEndpoint ?? pairing.lastEndpoint else { return nil }
            return (pairing.label, address)
        }

        info("looking over Bonjour for \(LinkListener.bonjourServiceType)…")
        let discovered = Discovery.scan(duration: 4)
        if discovered.isEmpty {
            warn("nothing advertising — Bonjour is blocked on many managed networks")
            if targets.isEmpty {
                bad("and no address is set for any pairing, so there is nothing to dial")
                out(Style.dim("    menu bar ▸ Devices ▸ <the Mac> ▸ Set address"))
                problems.append("no way to find the other Mac")
            }
        } else {
            for peer in discovered { ok("found \"\(peer.serviceName)\"  \(peer.deviceID?.short ?? "")") }
        }

        for (label, address) in targets {
            out()
            info("probing \(address) for '\(label)'…")
            let reachable = Reachability.check(address: address, defaultPort: config.port)
            switch reachable {
            case .open(let millis):
                ok(String(format: "port open, connected in %.0f ms", millis))
                if millis > 150 {
                    warn("that is slow for a local network")
                    problems.append("slow network")
                }
            case .refused:
                bad("the Mac answers but nothing is listening on that port")
                out(Style.dim("    Either it is not started, it is set to the wrong role, or its"))
                out(Style.dim("    firewall is blocking Edge. Check the menu bar over there."))
                problems.append("peer not listening")
            case .unreachable:
                bad("no answer at all — wrong address, or a different network")
                problems.append("peer unreachable")
            }
        }
        out()

        out(Style.bold("Verdict"))
        if problems.isEmpty {
            ok("nothing obviously wrong from this side")
            out(Style.dim("    If it still will not connect, check the other Mac's menu bar:"))
            out(Style.dim("    one Mac must be set to Primary and the other to Secondary."))
        } else {
            for problem in problems { bad(problem) }
        }
    }
}

/// Whether the macOS application firewall would stop a listening session being reached.
enum FirewallCheck {
    enum State { case off, on(blocked: Bool), unknown }

    private static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    static func state() -> State {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return .unknown }
        guard let global = run([ "--getglobalstate" ]) else { return .unknown }
        guard global.contains("enabled") || global.contains("State = 1") else { return .off }

        let path = Bundle.main.bundlePath
        guard let listed = run(["--getappblocked", path]) else {
            // Not in the list at all, which for an unsigned-by-Apple app means incoming
            // connections are refused rather than silently allowed.
            return .on(blocked: true)
        }
        return .on(blocked: listed.lowercased().contains("blocked"))
    }

    static func explainHowToAllow() {
        let path = Bundle.main.bundlePath
        out()
        out("    System Settings ▸ Network ▸ Firewall ▸ Options…, then add Edge")
        out("    and set it to “Allow incoming connections”. Or from a terminal:")
        out()
        out(Style.dim("      sudo \(tool) --add \"\(path)\""))
        out(Style.dim("      sudo \(tool) --unblockapp \"\(path)\""))
        out()
        out(Style.dim("    Only the secondary needs this — it is the one being"))
        out(Style.dim("    connected to. A managed Mac may not let you change it."))
    }

    private static func run(_ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Can we open a TCP connection to the other Mac, and how long does it take?
enum Reachability {
    enum Result {
        case open(millis: Double)
        case refused      // the Mac answered, nothing is listening
        case unreachable  // no answer at all
    }

    static func check(address: String, defaultPort: UInt16, timeout: TimeInterval = 4) -> Result {
        guard let endpoint = try? LinkConnector.parseEndpoint(address, defaultPort: defaultPort)
        else { return .unreachable }

        // A plain TCP connection: enough to tell "nothing is listening" from "nothing is
        // there", which are different problems with different fixes.
        let parameters = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: parameters)
        let outcome = Box<Result?>(nil)
        let started = Date()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.value = .open(millis: Date().timeIntervalSince(started) * 1000)
            case .failed(let error):
                if case .posix(.ECONNREFUSED) = error { outcome.value = .refused }
                else { outcome.value = .unreachable }
            case .waiting(let error):
                if case .posix(.ECONNREFUSED) = error { outcome.value = .refused }
            default:
                break
            }
        }
        connection.start(queue: .global())
        _ = Runtime.wait(until: { outcome.value != nil }, timeout: timeout)
        connection.cancel()
        return outcome.value ?? .unreachable
    }
}
