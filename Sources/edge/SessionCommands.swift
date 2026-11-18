import Foundation
import Network
import EdgeCore

/// Restarts a listener when the pairings on disk change.
///
/// The keys a listener will accept are fixed when its TLS parameters are built, so a session
/// that was already running when you paired a new Mac keeps offering the old key set and
/// turns the new one away with `errSSLUnknownPSKIdentity`. From the outside that looks like a
/// mistyped pairing code — the one explanation it is not — and no amount of re-pairing fixes
/// it, because the problem is on the side that is not being re-paired.
final class PairingWatcher {
    private var lastSeen: String
    private let onChange: () -> Void
    private var timer: DispatchSourceTimer?

    init(onChange: @escaping () -> Void) {
        self.lastSeen = SecretStore.keySetFingerprint
        self.onChange = onChange
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.edge.pairings"))
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = SecretStore.keySetFingerprint
            guard current != self.lastSeen else { return }
            self.lastSeen = current
            DispatchQueue.main.async { self.onChange() }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// Where session state is written from paths that must not wait on a disk: one serial
/// queue, so writes land in order and the last one wins.
private let stateWriter = DispatchQueue(label: "app.edge.state-writer", qos: .utility)

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
        guard !directory.snapshot.pairings.isEmpty else { throw EdgeError.notPaired }
        try refuseIfAlreadyRunning(.listening, replace: args.bool("replace"))

        // Injecting events into other apps needs Accessibility, and there is nothing useful
        // this command can do without it, so say so up front rather than failing silently
        // the first time the pointer arrives.
        let accessibility = Permissions.accessibility(prompt: !args.bool("no-prompt"))
        if !accessibility.isGranted {
            warn("Accessibility is \(accessibility) — this Mac can accept a link but cannot move its own pointer yet")
            explainAccessibility()
            if !args.bool("force") {
                out()
                info("Grant it and run `edge listen` again, or pass --force to listen anyway.")
                throw ExitSilently(code: Runtime.exitMissingPermission)
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
        let activity = SessionActivity(reason: "injecting keyboard and pointer input from another Mac")
        session.filesEnabled = config.fileSharing
        session.revealReceivedFiles = config.revealReceivedFiles
        let clipboardLimit = config.clipboardLimit
        let state = Box(RuntimeState(role: .listening))
        state.value.save()
        defer { RuntimeState.clear(.listening) }

        let options = LinkListener.Options(
            port: config.port,
            requireLocalNetwork: config.requireLocalNetwork,
            bonjourName: config.bonjourEnabled ? identity.deviceName : nil,
            // Deliberately not config.link: a listener restricted to one kind of link is
            // simply unreachable from a Mac that chose the other, and nothing says why. The
            // preference is about which link this Mac dials *out* on; accepting is free, so
            // accept on all of them and let the connecting side decide.
            link: .auto)

        let listener = LinkListener(identity: identity,
                                    localRole: .client,
                                    capabilities: config.capabilities,
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
            state.mutate {
                $0.connected = true
                $0.peerName = peer.name
                $0.endpoint = peer.endpoint
                $0.save()
            }
            ok("link up  ←  \(Style.bold(peer.name))  [\(peer.deviceID.short)]  \(peer.endpoint)")
            info("\(peer.tlsDescription)  ·  key \(String(Crypto.hex(peer.keyID).prefix(8)))")

            // A link that has not noticed it is dead yet may still hold the old bridge; its
            // polling timer has to stop before a new one takes over.
            session.clipboard?.detach()
            let clipboard = ClipboardBridge(config: config) { [weak link] message in
                link?.send(message)
            }
            clipboard.onActivity = { info("clipboard: \($0)") }
            clipboard.attach(peerCapabilities: peer.capabilities)
            state.mutate { $0.clipboardActive = clipboard.isActive; $0.save() }
            session.clipboard = clipboard
            session.clipboardLimit = clipboardLimit
            // Strong, like every other use of `directory` in this closure: it lives as long as
            // the command does, and a weak capture here only pretended otherwise.
            session.onPeerDisplays = { displays, keyID in
                directory.noteDisplays(displays, forKeyID: keyID)
            }
            session.attach(link: link)
            activity.update(linked: true, keepAwake: true)
        }

        listener.onLinkClosed = { linkID, peer, error in
            // A half-open link from before a reconnect can time out after its replacement is
            // already up. Detaching then would drop the new link's clipboard, input and state.
            guard session.isCurrent(linkID) else {
                Log.debug("an earlier link closed; the current one is unaffected")
                return
            }
            session.detach()
            activity.update(linked: false)
            state.mutate { $0.connected = false; $0.lastError = error?.localizedDescription; $0.save() }
            if let error { bad("link down: \(error.localizedDescription)") }
            else if let peer { info("link closed  ·  \(peer.name)") }
            info("waiting for the other Mac — Ctrl-C to stop")
        }

        listener.onFailure = { error in
            bad("listener failed: \(error.localizedDescription)")
            if case NWError.posix(.EADDRINUSE) = error {
                out(Style.dim("  Port \(config.port) is already taken. Another `edge listen` may be"))
                out(Style.dim("  running, or pick a different one with --port."))
            }
            exit(1)
        }

        // Opt out of App Nap here too.
        //
        // This was only ever done on the sending side, so a receiving session started from
        // the menu bar — a child of a background accessory app — was throttled and had its
        // timers coalesced. Injecting events late and answering heartbeats late is what a
        // 56 ms mean round trip on a LAN looks like, and why the terminal felt smooth and
        // the menu bar did not.
        //
        // While linked it also keeps this Mac awake. The secondary gets no input of its own
        // while you work on the primary, so it would otherwise idle-sleep mid-session and be
        // gone the next time the pointer crossed. With no link it is free to sleep.
        activity.update(linked: false)
        defer { activity.end() }

        try listener.start()
        session.startWatchingDisplays()
        Runtime.installSignalHandlers()
        // The menu-bar app asking to become the primary: ask the primary to swap, since it
        // holds the arrangement. If it cannot be asked, this Mac switches on its own.
        Runtime.onRoleSwitchSignal = {
            if !session.requestRoleSwitch() {
                RoleSwitchNote(becomePrimary: true, otherMacFollows: false).write()
            }
        }

        // Noticing a new pairing matters more than it sounds: without it, a session that was
        // running when you paired keeps refusing the new key for ever.
        var pairingsChanged = false
        let watcher = PairingWatcher { pairingsChanged = true }
        watcher.start()

        Runtime.run(while: { !Runtime.interrupted && !pairingsChanged })
        watcher.stop()

        if pairingsChanged && !Runtime.interrupted {
            out()
            info("the pairings changed — restarting so the new key is accepted")
            session.detach()
            session.stopWatchingDisplays()
            listener.stop()
            RuntimeState.clear(.listening)
            activity.end()
            // Give the port a moment to come free before binding it again.
            Thread.sleep(forTimeInterval: 0.4)
            return try listen(args)
        }

        out()
        info("shutting down")
        session.detach()
        session.stopWatchingDisplays()
        listener.stop()
    }

    // MARK: - connect  (the Mac with the keyboard and mouse)

    /// One attempt's outcome, and whether trying again could possibly help.
    private enum SessionOutcome {
        case ended                  // closed cleanly, or the user stopped it
        case dropped(Error?)        // lost the link; worth retrying
        case fatal(String, code: Int32 = 1)   // retrying would fail the same way
    }

    static func connect(_ args: Args) throws {
        let identity = try Identity.loadOrCreate()
        let config = try Config.load()
        let directory = try PairingDirectory.load()
        let shareInput = !args.bool("link-only")
        let retry = !args.bool("no-retry")
        try refuseIfAlreadyRunning(.sharing, replace: args.bool("replace"))

        // Built once and kept across reconnections. The event tap stays installed while the
        // link is down, which is safe by construction: with no link it swallows nothing.
        let sharing = shareInput ? SharingSession(config: config, remoteName: "the other Mac") : nil
        // Boxed because the session callbacks that update it outlive each call.
        var initial = RuntimeState(role: .sharing)
        initial.sharingInput = shareInput
        let state = Box(initial)
        state.value.save()
        defer { RuntimeState.clear(state.value.role) }

        Runtime.installSignalHandlers()

        var backoff: TimeInterval = 1
        var attempt = 0

        while !Runtime.interrupted {
            attempt += 1
            let outcome = runSession(args: args, identity: identity, config: config,
                                     directory: directory, sharing: sharing,
                                     state: state, attempt: attempt)

            switch outcome {
            case .ended:
                return
            case let .fatal(reason, code):
                Log.debug("not retrying: \(reason)")
                throw ExitSilently(code: code)
            case .dropped(let error):
                guard retry, !Runtime.interrupted else {
                    if let error { bad(error.localizedDescription) }
                    throw ExitSilently(code: error == nil ? 0 : 1)
                }
                if let error { warn(error.localizedDescription) }
                state.mutate {
                    $0.connected = false
                    $0.via = nil
                    $0.lastError = error?.localizedDescription
                    $0.save()
                }

                info(String(format: "reconnecting in %.0fs…  (Ctrl-C to stop)", backoff))
                let wake = Date().addingTimeInterval(backoff)
                while Date() < wake && !Runtime.interrupted {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                }
                // Back off gently, but never so far that coming back from a closed lid
                // takes a visible pause.
                backoff = min(backoff * 2, 20)
            }
        }

        sharing?.stop()
        out()
        info("stopped")
    }

    /// One connection, from dialling to the link closing.
    private static func runSession(args: Args, identity: Identity, config: Config,
                                   directory: PairingDirectory, sharing: SharingSession?,
                                   state: Box<RuntimeState>, attempt: Int) -> SessionOutcome {
        let target: Target.Resolved
        do {
            // Resolved fresh every time: the other Mac may have moved to a new address, which
            // is one of the commoner reasons a link drops in the first place.
            target = try Target.resolve(argument: args.arg(0),
                                        store: directory.snapshot,
                                        config: config,
                                        explicitPairing: args.string("pair"),
                                        localDeviceID: identity.deviceID,
                                        attempt: attempt)
        } catch {
            // Not being able to find the other Mac is nearly always "it is not listening
            // yet", which fixes itself the moment someone presses Start over there. Treating
            // it as fatal meant the menu bar reported a crash instead of waiting.
            if attempt == 1 { warn(error.localizedDescription) }
            else { Log.debug("still cannot find it: \(error.localizedDescription)") }
            return .dropped(nil)
        }

        let peerLabel = target.pairing.peerName ?? target.pairing.label
        info("dialling \(NetworkAddress.describe(target.endpoint))  ·  pairing '\(target.pairing.label)'  ·  via \(target.via)")

        let link = LinkConnector.connect(to: target.endpoint, psk: target.pairing.psk,
                                         identity: identity, localRole: .host,
                                         capabilities: config.capabilities,
                                         link: config.link)
        let heartbeat = Heartbeat(link: link)
        let closed = Box<(done: Bool, error: Error?)>((false, nil))
        // Files come back this way too: drag something on the other Mac towards the edge you
        // came from and it lands here.
        let files = FileReceiver()
        files.onReceived = { urls, from in
            ok("received \(urls.count) file(s) from \(from) into \(FileTransfer.destination.lastPathComponent)")
            if config.revealReceivedFiles { Reveal.inFinder(urls) }
        }
        files.onFailed = { reason in warn("files did not arrive: \(reason)") }
        defer { files.abandon() }
        let clipboard = ClipboardBridge(config: config) { [weak link] message in
            link?.send(message)
        }
        clipboard.onActivity = { info("clipboard: \($0)") }
        defer { clipboard.detach() }

        sharing?.onModeChange = { mode in
            switch mode {
            case .remote: out("  \(Style.cyan("→"))  pointer is on \(Style.bold(peerLabel))")
            case .local:  out("  \(Style.green("←"))  pointer is back on this Mac")
            }
        }

        sharing?.onFilesSent = { count, problem in
            if let problem { warn("files did not cross: \(problem)") }
            else { ok("carrying \(count) file(s) to \(peerLabel) — they land when you let go") }
        }

        // The release of the button, wherever the pointer happens to be. Told to both ends
        // because either of them may be holding staged files: the far one when the drag went
        // out, this one when it came back.
        sharing?.onDrop = { [weak link] in
            link?.send(.fileDrop)
            files.drop(from: link?.peer?.name ?? "the other Mac")
        }

        link.onReady = { peer in
            directory.note(peer: peer)
            sharing?.peerAcceptsFiles = peer.capabilities.contains(.files)
            sharing?.peerAcceptsMediaKeys = peer.capabilities.contains(.mediaKeys)
            ok("link up  →  \(Style.bold(peer.name))  [\(peer.deviceID.short)]  \(peer.endpoint)")
            info("\(peer.tlsDescription)  ·  key \(String(Crypto.hex(peer.keyID).prefix(8)))")
            out()
            link.send(.screenInfo(displays: Displays.current()))
            heartbeat.start()
            clipboard.attach(peerCapabilities: peer.capabilities)
            state.mutate { $0.clipboardActive = clipboard.isActive; $0.save() }
        }

        var printedSamples = 0
        heartbeat.onSample = { ms, stats in
            printedSamples += 1
            if printedSamples <= 3 || printedSamples % 30 == 0 {
                out(String(format: "  rtt %6.2f ms   \(Style.dim(stats.summary))", ms))
            }
            // Published for the menu bar, which has no link of its own to measure.
            if printedSamples % 5 == 0 {
                state.mutate { $0.rttMillis = stats.meanMillis; $0.save() }
            }
        }
        heartbeat.onTimeout = { seq in warn("heartbeat \(seq) lost") }

        // Swapping roles. Asked for by this Mac's menu-bar app (a signal) or by the other Mac
        // (a message); either way this side drives it, because only the primary knows the
        // arrangement to hand over — mirrored, since if the other Mac is to my right, I am to
        // its left. The note tells the menu-bar app to restart this Mac as the secondary.
        let handOver: () -> Void = { [weak link] in
            let follows = link?.peer?.capabilities.contains(.roleSwitch) == true
            if follows, let link {
                let current = (try? Config.load()) ?? config
                link.send(.switchRoles(edge: current.edge.opposite.rawValue,
                                       alignment: current.alignment.rawValue))
            }
            RoleSwitchNote(becomePrimary: false, otherMacFollows: follows).write()
            info(follows ? "swapping roles: \(peerLabel) becomes the primary"
                         : "becoming the secondary; \(peerLabel) cannot be told")
        }
        Runtime.onRoleSwitchSignal = handOver

        link.onMessage = { message in
            if case .requestRoleSwitch = message {
                DispatchQueue.main.async { handOver() }
                return
            }
            heartbeat.handle(message)
            sharing?.noteTraffic()
            clipboard.handle(message, limit: config.clipboardLimit)
            if config.fileSharing {
                files.handle(message, from: link.peer?.name ?? "the other Mac")
            }
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
            closed.value = (true, error)
        }
        link.start()

        guard Runtime.wait(until: { link.peer != nil || closed.value.done }, timeout: 15),
              let peer = link.peer else {
            let error = closed.value.error
                ?? EdgeError.timedOut("no answer from \(NetworkAddress.describe(target.endpoint))")
            return .dropped(error)
        }

        state.mutate {
            $0.connected = true
            $0.peerName = peer.name
            $0.endpoint = peer.endpoint
            $0.via = target.via
            $0.lastError = nil
            $0.save()
        }

        if let sharing {
            // Both ends on one Mac would feed the injected events straight back into the tap
            // that produced them, and each lap round that loop generates another event.
            if peer.deviceID == identity.deviceID || NetworkAddress.isLoopback(target.endpoint) {
                bad(peer.deviceID == identity.deviceID
                    ? "this link loops back to this same Mac"
                    : "this link runs over loopback, so both ends are this Mac")
                out()
                out("  Input sharing is refused here: the events this Mac injects would be")
                out("  picked up by its own event tap and sent round again.")
                out(Style.dim("    For a loopback transport test, use:  edge connect --link-only"))
                link.close(reason: "refusing to share input with myself")
                return .fatal("loopback")
            }

            // Mouse events reach a tap with Accessibility alone; keyboard events need Input
            // Monitoring as well. Without this check the session starts, the pointer crosses
            // over, and only then does it become apparent that typing does nothing.
            if !Permissions.inputMonitoring().isGranted {
                bad("Input Monitoring is not granted — the pointer would cross over but the keyboard would not follow")
                explainCapturePermissions()
                link.close(reason: "missing Input Monitoring")
                return .fatal("missing Input Monitoring", code: Runtime.exitMissingPermission)
            }

            if !sharing.isCapturing {
                do {
                    try sharing.start()
                    out()
                    ok("sharing this Mac's keyboard and mouse")
                    info("push the pointer off the \(config.edge.rawValue) edge of this Mac to cross over")
                    info("hold \(Style.bold("⌘ ⌥ ⌃ ⇧")) together at any time to bring it straight back")
                    out()
                } catch {
                    bad(error.localizedDescription)
                    explainCapturePermissions()
                    link.close(reason: "could not capture input")
                    // Almost always a permission that was granted to a different build of
                    // this app, so it reads as granted in Settings and is not.
                    return .fatal("could not install the event tap",
                                  code: Runtime.exitMissingPermission)
                }
            }
            sharing.onModeChange = { mode in
                // Called from inside the event tap at the moment of crossing. The file write
                // happens elsewhere: a disk write in the tap is time the pointer waits for.
                state.mutate { $0.pointerIsRemote = (mode == .remote) }
                stateWriter.async { state.value.save() }
                switch mode {
                case .remote: out("  \(Style.cyan("→"))  pointer is on \(Style.bold(peer.name))")
                case .local:  out("  \(Style.green("←"))  pointer is back on this Mac")
                }
            }
        }

        let duration = try? args.double("duration")
        let deadline = (duration ?? nil).map { Date().addingTimeInterval($0) }
        var sessionOver = false
        var reachedDeadline = false

        Runtime.run(while: { !Runtime.interrupted && !sessionOver }) {
            sharing?.checkLiveness()
            if closed.value.done { sessionOver = true }
            if let deadline, Date() >= deadline { sessionOver = true; reachedDeadline = true }
        }

        // Whatever ended the session, this Mac gets its pointer back.
        sharing?.detach(reason: "session ended")
        heartbeat.stop()

        let stats = heartbeat.snapshot
        if stats.samples > 0 {
            out()
            ok("latency over \(stats.samples) samples: \(stats.summary)")
        }
        if let forwarded = sharing?.forwardedCount, forwarded > 0 {
            let dropped = link.coalescedMoves
            if dropped > 0 {
                info("forwarded \(forwarded) pointer events, dropping \(dropped) stale positions "
                     + "the link was too slow to carry")
            } else {
                info("forwarded \(forwarded) pointer events")
            }
        }

        state.mutate { $0.connected = false; $0.pointerIsRemote = false; $0.via = nil; $0.save() }

        // Only a deliberate stop ends things; anything else is worth reconnecting after.
        if reachedDeadline || Runtime.interrupted {
            link.close(reason: "user stopped")
            out()
            info("disconnected")
            return .ended
        }
        return .dropped(closed.value.error)
    }

    /// Refuses to start when this Mac is already running a session of the same kind.
    static func refuseIfAlreadyRunning(_ role: RuntimeState.Role, replace: Bool) throws {
        // Any session, not just one of the same kind: one Mac runs one session.
        guard let other = RuntimeState.anyLive else { return }

        if replace {
            info("stopping the session already running as pid \(other.pid)")
            kill(other.pid, SIGINT)
            // Give it time to put the pointer back and un-hide the cursor on its way out.
            _ = Runtime.wait(until: { RuntimeState.anyLive == nil }, timeout: 4)
            if RuntimeState.anyLive != nil { kill(other.pid, SIGKILL) }
            return
        }

        let what = other.role == .sharing ? "running as the primary"
                                          : "running as the secondary"
        throw EdgeError.invalidArgument(
            "another Edge session is already \(what) (pid \(other.pid)).\n"
            + "  Two at once means two event taps and doubled traffic, which shows up as a\n"
            + "  laggy pointer and a cursor that will not stay hidden.\n"
            + "  Stop that one first, quit the menu-bar app, or pass --replace.")
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
        out(Style.dim("    change it with: edge config set remoteEdge left|right|top|bottom"))
        out()
    }
}

/// Everything the receiving Mac does with an established link: act on incoming events, keep
/// the other side informed about this Mac's screens, and clean up safely when it drops.
final class ReceivingSession {
    var clipboard: ClipboardBridge?
    var clipboardLimit: Int = 1 << 20
    var filesEnabled = true
    var revealReceivedFiles = true
    private let files = FileReceiver()
    /// A transfer this Mac is sending back, kept alive while it runs.
    private var sender: FileSender?
    /// Called when the other Mac reports its screens, so they can be remembered.
    var onPeerDisplays: (([Display], Data) -> Void)?
    private var cursorHidden: LocalPointer.CaptureState?
    private var cursorTimer: DispatchSourceTimer?
    private var lastInjectedAt = ScreenPoint(x: 0, y: 0)
    private let cursorQueue = DispatchQueue(label: "app.edge.client-cursor")
    private let injector: EventInjector
    private let watcher = DisplayWatcher()
    private var link: SecureLink?
    private let lock = NSLock()
    private var eventCount = 0
    private var lastReport = Date()

    init(injector: EventInjector) {
        self.injector = injector
        files.onReceived = { [weak self] urls, from in
            ok("received \(urls.count) file(s) from \(from) into \(FileTransfer.destination.lastPathComponent)")
            if self?.revealReceivedFiles == true { Reveal.inFinder(urls) }
        }
        files.onFailed = { reason in warn("files did not arrive: \(reason)") }
    }

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
        lock.lock()
        let replaced = currentLinkID.map { $0 != ObjectIdentifier(link) } ?? false
        self.link = link
        currentLinkID = ObjectIdentifier(link)
        lock.unlock()
        if replaced { Log.debug("a new link replaced one that had not closed yet") }
        link.onMessage = { [weak self] message in self?.handle(message) }
        // The sending Mac needs our screen arrangement to work out where its pointer should
        // go, so this is the first thing we say.
        link.send(.screenInfo(displays: Displays.current()))
    }

    private var currentLinkID: ObjectIdentifier?

    /// Whether `linkID` is the link this session is attached to now.
    /// Asks the primary to swap roles. False if there is no one to ask who understands.
    func requestRoleSwitch() -> Bool {
        lock.lock(); let link = self.link; lock.unlock()
        guard let link, link.peer?.capabilities.contains(.roleSwitch) == true else { return false }
        link.send(.requestRoleSwitch)
        return true
    }

    func isCurrent(_ linkID: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return currentLinkID == linkID
    }

    func detach() {
        lock.lock(); currentLinkID = nil; lock.unlock()
        // Whatever ended the link, this Mac gets its cursor back.
        showLocalCursor()
        clipboard?.detach()
        // A half-written file must never be left looking like a whole one.
        files.abandon()
        sender?.cancel(reason: "the link closed")
        sender = nil
        lock.lock(); link = nil; lock.unlock()
        // The link may have died mid-drag or with a modifier held.
        injector.releaseEverything()
    }

    private func handle(_ message: Message) {
        clipboard?.handle(message, limit: clipboardLimit)
        if filesEnabled {
            files.handle(message, from: link?.peer?.name ?? "the other Mac")
        }
        switch message {
        case .fileRequest:
            sendDraggedFiles()

        case let .mouseMove(x, y, dx, dy):
            let point = ScreenPoint(x: Double(x), y: Double(y))
            injector.move(to: point, delta: ScreenPoint(x: Double(dx), y: Double(dy)))
            lastInjectedAt = point
            countEvent()

        case let .mouseButton(button, down, clickCount, x, y):
            injector.button(button, down: down, clickCount: Int(clickCount),
                            at: ScreenPoint(x: Double(x), y: Double(y)))
            Log.debug("\(button) \(down ? "down" : "up") at (\(x), \(y)) ×\(clickCount)")

        case let .scroll(dx, dy, isPixel):
            injector.scroll(dx: dx, dy: dy, isPixel: isPixel)

        case let .keyEvent(code, down, isRepeat, flags):
            // Deliberately not logged, at any level: a line per key code is a keylog, and
            // session.log is a plain file anyone with this account can read.
            injector.key(code: code, down: down, isRepeat: isRepeat, flags: flags)

        case let .flagsChanged(flags):
            injector.changeFlags(flags)

        case let .switchRoles(edge, alignment):
            // The primary is handing over. The menu-bar app restarts this Mac as the primary
            // and shows the arrangement, already mirrored from the other side.
            RoleSwitchNote(becomePrimary: true, edge: edge, alignment: alignment,
                           otherMacFollows: true).write()
            info("the other Mac handed over: this Mac becomes the primary")

        case let .mediaKey(key, down, isRepeat):
            injector.mediaKey(MediaKey(key: key, down: down, isRepeat: isRepeat))
            Log.debug("media key \(key) \(down ? "down" : "up")")

        case let .enterScreen(x, y, flags):
            showLocalCursor()
            injector.setFlags(flags)
            injector.warp(to: ScreenPoint(x: Double(x), y: Double(y)))
            lastInjectedAt = ScreenPoint(x: Double(x), y: Double(y))
            Log.debug("pointer entered at (\(x), \(y))")

        case .leaveScreen:
            injector.releaseEverything()
            hideLocalCursor()
            Log.debug("pointer left")

        case let .screenInfo(displays):
            // Record them, not merely note them. Only the dialling side was storing this, so
            // the Mac lending its screen could be connected for an hour and still have
            // nothing to show for the arrangement.
            if let keyID = link?.peer?.keyID {
                onPeerDisplays?(displays, keyID)
            }
            Log.debug("the other Mac has \(displays.count) display(s)")

        default:
            break
        }
    }


    /// The pointer is leaving and a drag is open here: send what is in it.
    ///
    /// Asked for by the other Mac rather than decided here, because this Mac has no event tap
    /// and so no idea the pointer is about to go. The question always arrives before the
    /// message that releases the button, so the pasteboard is still intact when it is read.
    private func sendDraggedFiles() {
        lock.lock(); let link = self.link; lock.unlock()
        guard filesEnabled, let link else { return }
        let urls = DraggedFiles.current()
        guard !urls.isEmpty else { return }

        DraggedFiles.cancelLocalDrag(releasingAt: lastInjectedAt)
        let sender = FileSender(link: link)
        sender.onStarted = { count, bytes in ok("sending \(count) file(s) back, \(bytes) bytes") }
        sender.onFinished = { [weak self] reason in
            if let reason { warn("files did not cross: \(reason)") }
            self?.sender = nil
        }
        self.sender = sender
        if !sender.start(urls: urls) { self.sender = nil }
    }

    // MARK: - This Mac's own cursor

    /// Hides this Mac's cursor while the pointer is on the other one.
    ///
    /// Without it, the Mac you just left keeps showing a cursor sitting wherever the pointer
    /// happened to be — which is the same "two pointers" complaint as before, just from the
    /// other side of the link.
    ///
    /// Not uncoupled from the hardware, unlike the sending Mac: this machine still has its
    /// own trackpad, and taking it away would be worse than a stray cursor. Instead the
    /// cursor is watched, and if it moves while nothing is being injected then somebody is
    /// using this Mac directly and it comes straight back.
    private func hideLocalCursor() {
        lock.lock()
        guard cursorHidden == nil else { lock.unlock(); return }
        let state = LocalPointer.hideOnly()
        cursorHidden = state
        lastInjectedAt = LocalPointer.liveLocation
        lock.unlock()

        if !state.hidden {
            Log.debug("could not hide this Mac's cursor (\(state.summary))")
        }

        let timer = DispatchSource.makeTimerSource(queue: cursorQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in self?.checkForLocalUse() }
        cursorTimer = timer
        timer.resume()
    }

    private func showLocalCursor() {
        cursorTimer?.cancel()
        cursorTimer = nil
        lock.lock()
        let state = cursorHidden
        cursorHidden = nil
        lock.unlock()
        if let state { LocalPointer.endCapture(state, restoringTo: nil) }
    }

    /// Is somebody using this Mac's own mouse? Then stop hiding its cursor.
    private func checkForLocalUse() {
        lock.lock()
        let hidden = cursorHidden != nil
        let expected = lastInjectedAt
        lock.unlock()
        guard hidden else { return }

        let actual = LocalPointer.liveLocation
        let moved = abs(actual.x - expected.x) + abs(actual.y - expected.y)
        // Nothing is being injected while the pointer is away, so any movement is local.
        guard moved > 3 else { return }
        Log.debug("this Mac's own pointer moved — showing its cursor again")
        showLocalCursor()
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
        out(Style.dim("    Then run:          build/edge connect"))
    }
    out()
    out(Style.dim("    After changing either one, quit and start this command again —"))
    out(Style.dim("    macOS only re-reads them when the process starts."))
}

/// macOS will not tell an app why it was refused, and the checkbox is several clicks deep,
/// so spell out the exact path rather than leaving the user to hunt for it.
func explainAccessibility() {
    out()
    out("  To let Edge move this Mac's pointer and type on it:")
    out("    1. System Settings ▸ Privacy & Security ▸ \(Style.bold("Accessibility"))")
    out("    2. Add or tick \(Style.bold("Edge"))")
    if !Permissions.isRunningInsideAppBundle {
        out()
        warn("You are running the bare binary, so the permission would attach to your terminal.")
        out("    Build the bundle first:  \(Style.bold("Scripts/build.sh"))")
        out("    then run:                \(Style.bold("build/edge listen"))")
    } else {
        out()
        out(Style.dim("    The app is at: \(Bundle.main.bundlePath)"))
        out(Style.dim("    If it is already ticked but still refused, untick and re-tick it —"))
        out(Style.dim("    a rebuild changes the signature and macOS treats it as a new app."))
    }
    out()
    out(Style.dim("    Open it now with:  edge permissions"))
}
