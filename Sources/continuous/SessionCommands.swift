import Foundation
import Network
import ContinuousCore

extension Commands {

    // MARK: - listen  (the Mac lending its screen)

    static func listen(_ args: Args) throws {
        let identity = try Identity.loadOrCreate()
        var config = try Config.load()
        if let p = try args.uint16("port") { config.port = p }
        if args.bool("no-bonjour") { config.bonjourEnabled = false }
        if args.bool("allow-public") { config.requireLocalNetwork = false }

        let directory = try PairingDirectory.load()
        directory.allowRebind = args.bool("rebind")
        guard !directory.snapshot.pairings.isEmpty else { throw ContinuousError.notPaired }

        // Injecting events into other apps needs Accessibility, and there is nothing useful
        // this command can do without it, so say so up front rather than failing silently
        // the first time the pointer arrives.
        let accessibility = Permissions.accessibility(prompt: !args.bool("no-prompt"))
        if !accessibility.isGranted {
            warn("Accessibility is \(accessibility) — this Mac can accept a link but cannot move its own pointer yet")
            explainAccessibility()
            if !args.bool("force") {
                out()
                info("Grant it and run `continuous listen` again, or pass --force to listen anyway.")
                throw ExitSilently(code: 1)
            }
        }

        if !config.requireLocalNetwork {
            warn("--allow-public: this Mac will accept links from any address, not just your network")
        }
        if directory.allowRebind {
            warn("--rebind: a pairing may be re-bound to a different Mac on the next connection")
        }

        directory.onBind = { pairing in
            ok("pairing '\(pairing.label)' is now pinned to \(pairing.peerDeviceID?.short ?? "?") (\(pairing.peerName ?? "unnamed"))")
        }

        let injector = EventInjector()
        let session = ReceivingSession(injector: injector)

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

        listener.onListening = { port in
            ok("listening on port \(Style.bold(String(port)))  ·  \(identity.deviceName)  ·  \(identity.deviceID.short)")
            if config.bonjourEnabled { info("advertising over Bonjour as \"\(identity.deviceName)\"") }
            describeLocalScreens()
            out()
            for (name, addr) in LocalInterfaces.list() {
                out(Style.dim("    reachable at \(addr.split(separator: " ")[0]):\(port)   (\(name))"))
            }
            out()
            info("waiting for the other Mac — Ctrl-C to stop")
        }

        listener.onRejected = { endpoint, reason in warn("refused \(endpoint): \(reason)") }

        listener.onLinkReady = { link, peer in
            directory.note(peer: peer)
            ok("link up  ←  \(Style.bold(peer.name))  [\(peer.deviceID.short)]  \(peer.endpoint)")
            info("\(peer.tlsDescription)  ·  key \(String(Crypto.hex(peer.keyID).prefix(8)))")
            session.attach(link: link)
        }

        listener.onLinkClosed = { peer, error in
            session.detach()
            if let error { bad("link down: \(error.localizedDescription)") }
            else if let peer { info("link closed  ·  \(peer.name)") }
            info("waiting for the other Mac — Ctrl-C to stop")
        }

        listener.onFailure = { error in
            bad("listener failed: \(error.localizedDescription)")
            if case NWError.posix(.EADDRINUSE) = error {
                out(Style.dim("  Port \(config.port) is already taken. Another `continuous listen` may be"))
                out(Style.dim("  running, or pick a different one with --port."))
            }
            exit(1)
        }

        try listener.start()
        session.startWatchingDisplays()
        Runtime.installSignalHandlers()
        Runtime.runUntilInterrupted()

        out()
        info("shutting down")
        session.detach()
        session.stopWatchingDisplays()
        listener.stop()
    }

    // MARK: - connect  (the Mac with the keyboard and mouse)

    static func connect(_ args: Args) throws {
        let identity = try Identity.loadOrCreate()
        let config = try Config.load()
        let directory = try PairingDirectory.load()

        let target = try Target.resolve(argument: args.arg(0),
                                        store: directory.snapshot,
                                        config: config,
                                        explicitPairing: args.string("pair"))

        info("dialling \(NetworkAddress.describe(target.endpoint))  ·  pairing '\(target.pairing.label)'  ·  via \(target.via)")

        let link = LinkConnector.connect(to: target.endpoint,
                                         psk: target.pairing.psk,
                                         identity: identity,
                                         localRole: .host)
        let heartbeat = Heartbeat(link: link)
        let state = Box<(done: Bool, failure: Error?)>((false, nil))

        // `--link-only` keeps the milestone-1/2 behaviour: hold the link open and report
        // latency, without touching this Mac's keyboard or pointer. Useful for diagnosing a
        // network problem without also wondering whether the event tap is at fault.
        let shareInput = !args.bool("link-only")
        let sharing = shareInput ? SharingSession(config: config,
                                                  remoteName: target.pairing.peerName
                                                      ?? target.pairing.label) : nil

        sharing?.onModeChange = { mode in
            switch mode {
            case .remote: out("  \(Style.cyan("→"))  pointer is on \(Style.bold(target.pairing.peerName ?? target.pairing.label))")
            case .local:  out("  \(Style.green("←"))  pointer is back on this Mac")
            }
        }

        link.onReady = { peer in
            directory.note(peer: peer)
            ok("link up  →  \(Style.bold(peer.name))  [\(peer.deviceID.short)]  \(peer.endpoint)")
            info("\(peer.tlsDescription)  ·  key \(String(Crypto.hex(peer.keyID).prefix(8)))")
            out()
            // Tell the other Mac about our screens too; from milestone 3 it matters in both
            // directions, and it makes the handshake symmetric now.
            link.send(.screenInfo(displays: Displays.current()))
            heartbeat.start()
            sharing?.attach(link: link, layout: nil)
        }

        var printedSamples = 0
        heartbeat.onSample = { ms, stats in
            printedSamples += 1
            if printedSamples <= 3 || printedSamples % 15 == 0 {
                out(String(format: "  rtt %6.2f ms   \(Style.dim(stats.summary))", ms))
            }
        }
        heartbeat.onTimeout = { seq in warn("heartbeat \(seq) lost") }

        link.onMessage = { message in
            heartbeat.handle(message)
            sharing?.noteTraffic()
            if case let .screenInfo(displays) = message {
                directory.noteDisplays(displays, forKeyID: link.peer?.keyID ?? Data())
                let name = link.peer?.name ?? target.pairing.label
                reportLayout(remoteDisplays: displays, remoteName: name, config: config)
                if let layout = ScreenLayout(localDisplays: Displays.current(),
                                             remoteDisplays: displays,
                                             edge: config.edge, alignment: config.alignment) {
                    sharing?.update(layout: layout)
                    sharing?.attach(link: link, layout: layout)
                }
            }
        }

        link.onClose = { error in
            sharing?.detach(reason: "the link closed")
            state.value = (true, error)
        }
        link.start()
        Runtime.installSignalHandlers()

        // The tap is installed only once we know the link is up, so a failure to connect
        // never leaves this Mac with its input being swallowed.
        if let sharing {
            guard Runtime.wait(until: { link.peer != nil || state.value.done }, timeout: 15),
                  let peer = link.peer else {
                if let err = state.value.failure { bad(err.localizedDescription) }
                else { bad("could not establish the link") }
                throw ExitSilently(code: 1)
            }

            // Both ends on one Mac would feed the injected events straight back into the
            // tap that produced them, and each lap round that loop generates another event.
            // Harmless as a transport test, which is why --link-only still allows it.
            let sameDevice = peer.deviceID == identity.deviceID
            let overLoopback = NetworkAddress.isLoopback(target.endpoint)
            if sameDevice || overLoopback {
                bad(sameDevice ? "this link loops back to this same Mac"
                               : "this link runs over loopback, so both ends are this Mac")
                out()
                out("  Input sharing is refused here: the events this Mac injects would be")
                out("  picked up by its own event tap and sent round again.")
                out(Style.dim("    For a loopback transport test, use:  continuous connect --link-only"))
                link.close(reason: "refusing to share input with myself")
                throw ExitSilently(code: 1)
            }
            // Mouse events reach a tap with Accessibility alone; keyboard events need Input
            // Monitoring as well. Without that check the session starts, the pointer crosses
            // over, and only then does it become apparent that typing does nothing.
            if !Permissions.inputMonitoring().isGranted {
                bad("Input Monitoring is not granted — the pointer would cross over but the keyboard would not follow")
                explainCapturePermissions()
                link.close(reason: "missing Input Monitoring")
                throw ExitSilently(code: 1)
            }
            do {
                try sharing.start()
                out()
                ok("sharing this Mac's keyboard and mouse")
                let edgeWord: String
                switch config.edge {
                case .right: edgeWord = "right edge"
                case .left: edgeWord = "left edge"
                case .top: edgeWord = "top edge"
                case .bottom: edgeWord = "bottom edge"
                }
                info("push the pointer off the \(edgeWord) of this Mac to cross over")
                info("hold \(Style.bold("⌘ ⌥ ⌃ ⇧")) together at any time to bring it straight back")
                out()
            } catch {
                bad(error.localizedDescription)
                explainCapturePermissions()
                link.close(reason: "could not capture input")
                throw ExitSilently(code: 1)
            }
        }

        let duration = try args.double("duration")
        let deadline = duration.map { Date().addingTimeInterval($0) }
        Runtime.runUntilInterrupted {
            sharing?.checkLiveness()
            if state.value.done { Runtime.interrupted = true }
            if let deadline, Date() >= deadline { Runtime.interrupted = true }
        }

        // Always give this Mac its pointer back, whatever ended the session.
        sharing?.stop()
        heartbeat.stop()
        let stats = heartbeat.snapshot
        if stats.samples > 0 {
            out()
            ok("latency over \(stats.samples) samples: \(stats.summary)")
        }

        if let forwarded = sharing?.forwardedCount, forwarded > 0 {
            info("forwarded \(forwarded) pointer events")
        }

        if let err = state.value.failure {
            bad(err.localizedDescription)
            throw ExitSilently(code: 1)
        }
        link.close(reason: "user stopped")
        out()
        info("disconnected")
    }

    // MARK: - shared reporting

    static func describeLocalScreens() {
        let displays = Displays.current()
        let bounds = ScreenRect.union(displays.map(\.rect))
        info("\(displays.count) display\(displays.count == 1 ? "" : "s")"
             + (bounds.map { ", \(Int($0.width))×\(Int($0.height)) overall" } ?? ""))
        for (i, d) in displays.enumerated() {
            out(Style.dim("    \(i + 1). \(d.rect)\(d.isMain ? "  (main)" : "")"))
        }
    }

    /// Prints the combined desktop once the other Mac has told us about its screens.
    static func reportLayout(remoteDisplays: [Display], remoteName: String, config: Config) {
        guard let layout = ScreenLayout(localDisplays: Displays.current(),
                                        remoteDisplays: remoteDisplays,
                                        edge: config.edge,
                                        alignment: config.alignment) else { return }
        out()
        info("\(remoteName) has \(remoteDisplays.count) display\(remoteDisplays.count == 1 ? "" : "s") — arrangement is now:")
        out()
        out(layout.diagram(localName: "this Mac", remoteName: remoteName))
        out()
        out(Style.dim("    # this Mac    + \(remoteName)    edge: \(config.edge.rawValue), alignment: \(config.alignment.rawValue)"))
        out(Style.dim("    change it with: continuous config set remoteEdge left|right|top|bottom"))
        out()
    }
}

/// Everything the receiving Mac does with an established link: act on incoming events, keep
/// the other side informed about this Mac's screens, and clean up safely when it drops.
final class ReceivingSession {
    private let injector: EventInjector
    private let watcher = DisplayWatcher()
    private var link: SecureLink?
    private let lock = NSLock()
    private var eventCount = 0
    private var lastReport = Date()

    init(injector: EventInjector) { self.injector = injector }

    func startWatchingDisplays() {
        watcher.onChange = { [weak self] displays in
            guard let self else { return }
            info("this Mac's displays changed — \(displays.count) now; telling the other Mac")
            Commands.describeLocalScreens()
            self.lock.lock(); let link = self.link; self.lock.unlock()
            link?.send(.screenInfo(displays: displays))
        }
        watcher.start()
    }

    func stopWatchingDisplays() { watcher.stop() }

    func attach(link: SecureLink) {
        lock.lock(); self.link = link; lock.unlock()
        link.onMessage = { [weak self] message in self?.handle(message) }
        // The sending Mac needs our screen arrangement to work out where its pointer should
        // go, so this is the first thing we say.
        link.send(.screenInfo(displays: Displays.current()))
    }

    func detach() {
        lock.lock(); link = nil; lock.unlock()
        // The link may have died mid-drag or with a modifier held.
        injector.releaseEverything()
    }

    private func handle(_ message: Message) {
        switch message {
        case let .mouseMove(x, y, dx, dy):
            injector.move(to: ScreenPoint(x: Double(x), y: Double(y)),
                          delta: ScreenPoint(x: Double(dx), y: Double(dy)))
            countEvent()

        case let .mouseButton(button, down, clickCount, x, y):
            injector.button(button, down: down, clickCount: Int(clickCount),
                            at: ScreenPoint(x: Double(x), y: Double(y)))
            Log.debug("\(button) \(down ? "down" : "up") at (\(x), \(y)) ×\(clickCount)")

        case let .scroll(dx, dy, isPixel):
            injector.scroll(dx: dx, dy: dy, isPixel: isPixel)

        case let .keyEvent(code, down, isRepeat, flags):
            injector.key(code: code, down: down, isRepeat: isRepeat, flags: flags)
            Log.debug("key \(down ? "down" : "up  ") code \(code) flags \(String(flags, radix: 16))")

        case let .flagsChanged(flags):
            injector.changeFlags(flags)

        case let .enterScreen(x, y, flags):
            injector.setFlags(flags)
            injector.warp(to: ScreenPoint(x: Double(x), y: Double(y)))
            Log.debug("pointer entered at (\(x), \(y))")

        case .leaveScreen:
            injector.releaseEverything()
            Log.debug("pointer left")

        case let .screenInfo(displays):
            Log.debug("the other Mac has \(displays.count) display(s)")

        default:
            break
        }
    }

    /// Pointer moves arrive in the hundreds per second; log a rate, not a line per event.
    private func countEvent() {
        lock.lock()
        eventCount += 1
        let elapsed = Date().timeIntervalSince(lastReport)
        let shouldReport = elapsed >= 2 && eventCount > 0
        let count = eventCount
        if shouldReport { eventCount = 0; lastReport = Date() }
        lock.unlock()
        if shouldReport {
            Log.debug(String(format: "injected %.0f pointer events/s", Double(count) / elapsed))
        }
    }
}

struct ExitSilently: Error {
    let code: Int32
}

/// Capturing input needs *both* privacy permissions, and macOS reports neither of them
/// through the API that fails — `CGEvent.tapCreate` just returns nil.
func explainCapturePermissions() {
    out()
    out("  Sharing this Mac's keyboard and mouse needs two permissions, both of them:")
    out("    System Settings ▸ Privacy & Security ▸ \(Style.bold("Input Monitoring"))   \(Permissions.inputMonitoring().isGranted ? Style.green("granted") : Style.red("missing"))")
    out("    System Settings ▸ Privacy & Security ▸ \(Style.bold("Accessibility"))      \(Permissions.accessibility().isGranted ? Style.green("granted") : Style.red("missing"))")
    out()
    if Permissions.isRunningInsideAppBundle {
        out(Style.dim("    Grant them to: \(Bundle.main.bundlePath)"))
    } else {
        out("  You are running the bare binary, so these attach to whatever launched it —")
        out("  your terminal or editor, which is a far broader grant than you need.")
        out(Style.dim("    Build the bundle:  Scripts/build.sh"))
        out(Style.dim("    Then run:          build/continuous connect"))
    }
    out()
    out(Style.dim("    After changing either one, quit and start this command again —"))
    out(Style.dim("    macOS only re-reads them when the process starts."))
}

/// macOS will not tell an app why it was refused, and the checkbox is several clicks deep,
/// so spell out the exact path rather than leaving the user to hunt for it.
func explainAccessibility() {
    out()
    out("  To let Continuous move this Mac's pointer and type on it:")
    out("    1. System Settings ▸ Privacy & Security ▸ \(Style.bold("Accessibility"))")
    out("    2. Add or tick \(Style.bold("Continuous"))")
    if !Permissions.isRunningInsideAppBundle {
        out()
        warn("You are running the bare binary, so the permission would attach to your terminal.")
        out("    Build the bundle first:  \(Style.bold("Scripts/build.sh"))")
        out("    then run:                \(Style.bold("build/continuous listen"))")
    } else {
        out()
        out(Style.dim("    The app is at: \(Bundle.main.bundlePath)"))
        out(Style.dim("    If it is already ticked but still refused, untick and re-tick it —"))
        out(Style.dim("    a rebuild changes the signature and macOS treats it as a new app."))
    }
    out()
    out(Style.dim("    Open it now with:  continuous permissions"))
}
