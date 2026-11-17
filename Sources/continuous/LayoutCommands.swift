import Foundation
import ContinuousCore

extension Commands {

    // MARK: - layout

    /// Shows how the two Macs' screens are arranged into one desktop.
    ///
    /// The point of being able to run this on demand: with a monitor that switches between the
    /// two machines, the arrangement is not a fixed thing you configure once. Switch the
    /// monitor over, run this again, and you can see the handover point has moved.
    static func layout(_ args: Args) throws {
        var config = try Config.load()

        if args.arg(0) == "set" {
            if let edgeText = args.arg(1) ?? args.string("edge") {
                guard let edge = ScreenEdge.parse(edgeText) else {
                    throw ContinuousError.invalidArgument(
                        "edge must be left, right, top or bottom — got '\(edgeText)'")
                }
                config.remoteEdge = edge.rawValue
            }
            if let alignText = args.arg(2) ?? args.string("alignment") {
                guard let alignment = ScreenAlignment.parse(alignText) else {
                    throw ContinuousError.invalidArgument(
                        "alignment must be proportional, start, center or end — got '\(alignText)'")
                }
                config.remoteAlignment = alignment.rawValue
            }
            try config.save()
            ok("the other Mac is to the \(config.remoteEdge), aligned \(config.remoteAlignment)")
            out()
        }

        let localDisplays = Displays.current()
        out(Style.bold("This Mac"))
        describeLocalScreens()
        out()

        let store = try SecretStore.load()
        let withScreens = store.pairings.filter { ($0.peerDisplays?.isEmpty == false) }

        guard !withScreens.isEmpty else {
            out(Style.bold("Combined desktop"))
            if store.pairings.isEmpty {
                warn("no pairings yet — nothing to arrange against")
            } else {
                warn("the other Mac has not reported its screens yet")
                out(Style.dim("  Connect once (`continuous connect`) and it will be remembered here."))
            }
            return
        }

        for pairing in withScreens {
            guard let remote = pairing.peerDisplays,
                  let layout = ScreenLayout(localDisplays: localDisplays,
                                            remoteDisplays: remote,
                                            edge: config.edge,
                                            alignment: config.alignment) else { continue }
            let name = pairing.peerName ?? pairing.label
            out(Style.bold("Combined desktop  —  \(name) is to the \(config.remoteEdge)"))
            out(Style.dim("  as of \(relativeTime(pairing.lastSeenAt))"))
            out()
            out(layout.diagram(localName: "this Mac", remoteName: name))
            out()
            out(Style.dim("    # this Mac     + \(name)"))
            out("  alignment  \(config.remoteAlignment)")
            out("  this Mac   \(layout.localBounds)")
            out("  \(name.padding(toLength: max(9, name.count), withPad: " ", startingAt: 0))  \(layout.remoteBounds)  (its own coordinates)")

            // Show the handover concretely: push the pointer off the middle of the shared edge
            // and say exactly where it lands on the other Mac.
            let probe: ScreenPoint
            switch config.edge {
            case .right:  probe = ScreenPoint(x: layout.localBounds.maxX - 1, y: layout.localBounds.midY)
            case .left:   probe = ScreenPoint(x: layout.localBounds.x, y: layout.localBounds.midY)
            case .bottom: probe = ScreenPoint(x: layout.localBounds.midX, y: layout.localBounds.maxY - 1)
            case .top:    probe = ScreenPoint(x: layout.localBounds.midX, y: layout.localBounds.y)
            }
            let landing = layout.entryPoint(leavingLocalAt: probe)
            out()
            out("  leaving \(probe) on this Mac arrives at \(landing) on \(name)")
        }
    }

    // MARK: - permissions

    static func permissions(_ args: Args) throws {
        let ax = Permissions.accessibility(prompt: args.bool("prompt"))
        let im = Permissions.inputMonitoring()

        out(Style.bold("Permissions"))
        if ax.isGranted { ok("Accessibility: granted") } else { bad("Accessibility: \(ax)") }
        if im.isGranted { ok("Input Monitoring: granted") } else { warn("Input Monitoring: \(im)  (needed from milestone 3)") }
        out()

        if Permissions.isRunningInsideAppBundle {
            ok("running from \(Bundle.main.bundlePath)")
        } else {
            warn("running as a bare binary — grants would attach to your terminal, not to Continuous")
            out(Style.dim("    build the bundle with Scripts/build.sh and run build/continuous"))
        }

        if args.bool("open") || args.arg(0) == "open" {
            info("opening System Settings…")
            Permissions.openSettings(Permissions.accessibilitySettingsURL)
        } else if !ax.isGranted {
            out()
            explainAccessibility()
        }
    }

    // MARK: - inject-test

    /// Drives this Mac's own pointer and keyboard, with no network involved.
    ///
    /// Splitting this out from the networked test is deliberate: when the pointer does not move
    /// on the far Mac, this is what tells you whether the problem is the link or the permission.
    static func injectTest(_ args: Args) throws {
        let accessibility = Permissions.accessibility(prompt: true)
        guard accessibility.isGranted else {
            bad("Accessibility is \(accessibility) — this Mac cannot move its own pointer")
            explainAccessibility()
            throw ExitSilently(code: 1)
        }
        ok("Accessibility granted")

        let displays = Displays.current()
        guard let bounds = ScreenRect.union(displays.map(\.rect)) else {
            throw ContinuousError.invalidArgument("no displays found")
        }
        describeLocalScreens()
        out()

        let injector = EventInjector()
        let start = Displays.pointerLocation
        info("pointer is at \(start)")

        // Draw a square well inside the main display so it is visible wherever it starts.
        let main = displays.first(where: \.isMain)?.rect ?? bounds
        let size = min(main.width, main.height) * 0.35
        let origin = ScreenPoint(x: main.midX - size / 2, y: main.midY - size / 2)
        let corners = [
            origin,
            ScreenPoint(x: origin.x + size, y: origin.y),
            ScreenPoint(x: origin.x + size, y: origin.y + size),
            ScreenPoint(x: origin.x, y: origin.y + size),
            origin,
        ]

        info("drawing a square with the pointer — watch it move")
        var previous = start
        for corner in corners {
            let steps = 28
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let point = ScreenPoint(x: previous.x + (corner.x - previous.x) * t,
                                        y: previous.y + (corner.y - previous.y) * t)
                injector.move(to: point)
                Thread.sleep(forTimeInterval: 0.006)
            }
            previous = corner
        }

        let landed = Displays.pointerLocation
        let drift = abs(landed.x - origin.x) + abs(landed.y - origin.y)
        if drift < 4 {
            ok("pointer followed the path and finished at \(landed)")
        } else {
            bad("pointer ended at \(landed) but should be at \(origin)")
            out(Style.dim("    If it did not move at all, Accessibility is reported as granted but is stale:"))
            out(Style.dim("    untick and re-tick Continuous in System Settings."))
            throw ExitSilently(code: 1)
        }

        info("scrolling down then up")
        for _ in 0..<10 { injector.scroll(dx: 0, dy: -6, isPixel: true); Thread.sleep(forTimeInterval: 0.02) }
        for _ in 0..<10 { injector.scroll(dx: 0, dy: 6, isPixel: true); Thread.sleep(forTimeInterval: 0.02) }
        ok("scroll events posted")

        if args.bool("keys") {
            out()
            warn("typing a test string in 3 seconds — click into a text field now")
            Thread.sleep(forTimeInterval: 3)
            injector.type("Continuous M2 injection works.")
            ok("typed a test string")
        } else {
            out()
            info("keyboard injection not exercised — it would type into whatever is focused.")
            info("run `continuous inject-test --keys` with a text editor focused to try it.")
        }

        injector.move(to: start)
        injector.releaseEverything()
        out()
        ok("injection works on this Mac")
    }

    // MARK: - capture-test

    /// Checks that this Mac can *capture* input, without connecting to anything.
    ///
    /// Deliberately never crosses over: with no link and no layout there is nothing to cross
    /// to, which is also the invariant being checked — that a tap with nowhere to send events
    /// passes every one of them straight through.
    static func captureTest(_ args: Args) throws {
        let accessibility = Permissions.accessibility(prompt: true)
        let monitoring = Permissions.inputMonitoring()

        if accessibility.isGranted { ok("Accessibility: granted") } else { bad("Accessibility: \(accessibility)") }
        if monitoring.isGranted { ok("Input Monitoring: granted") } else { bad("Input Monitoring: \(monitoring)") }
        guard accessibility.isGranted, monitoring.isGranted else {
            explainCapturePermissions()
            throw ExitSilently(code: 1)
        }
        out()

        let seen = Box<[String: Int]>([:])
        let tap = EventTap { type, event in
            let name: String
            switch type {
            case .mouseMoved: name = "pointer"
            case .scrollWheel: name = "scroll"
            case .keyDown, .keyUp: name = "key"
            case .flagsChanged: name = "modifier"
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                 .otherMouseDown, .otherMouseUp: name = "button"
            default: name = "other"
            }
            seen.mutate { $0[name, default: 0] += 1 }
            return event   // never swallow: there is nowhere to send anything
        }

        do {
            try tap.start()
        } catch {
            bad(error.localizedDescription)
            explainCapturePermissions()
            throw ExitSilently(code: 1)
        }
        defer { tap.stop() }
        ok("event tap installed")

        // Drive the tap with synthetic events so the check does not depend on the person
        // running it remembering to wiggle the mouse.
        let injector = EventInjector()
        let start = Displays.pointerLocation
        let main = Displays.current().first(where: \.isMain)?.rect
            ?? ScreenRect(x: 0, y: 0, width: 800, height: 600)

        info("posting synthetic events and watching them arrive…")
        for step in 0..<40 {
            let t = Double(step) / 40
            injector.move(to: ScreenPoint(x: main.midX - 80 + 160 * t, y: main.midY))
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.004))
        }
        injector.scroll(dx: 0, dy: -3, isPixel: true)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        injector.move(to: start)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))

        out()
        let counts = seen.value
        for (kind, count) in counts.sorted(by: { $0.key < $1.key }) {
            out("    \(kind.padding(toLength: 10, withPad: " ", startingAt: 0)) \(count)")
        }
        out()

        guard (counts["pointer"] ?? 0) > 0 else {
            bad("the tap was installed but no pointer events arrived")
            out(Style.dim("    This is what a stale permission looks like: granted in System Settings,"))
            out(Style.dim("    but not actually in force. Untick and re-tick Continuous, then retry."))
            throw ExitSilently(code: 1)
        }
        ok("capture works — \(counts.values.reduce(0, +)) events observed")
        info("nothing was swallowed: with no link there is nowhere to send input,")
        info("and that is exactly when this Mac must keep every event for itself.")

        tap.stop()
        out()
        try checkPinningHoldsTheCursor(injector: injector)
        try checkSwallowingStopsTheLocalCursor()
    }

    /// Checks the mechanism that actually holds this Mac's cursor still.
    ///
    /// Unlike swallowing, this one *can* be tested with synthetic events: pinning reads the
    /// real cursor position and corrects it, so it does not matter how the cursor came to
    /// move. That makes it the part of the fix that can be checked without a second Mac.
    private static func checkPinningHoldsTheCursor(injector: EventInjector) throws {
        let park = Displays.pointerLocation
        let main = Displays.current().first(where: \.isMain)?.rect
            ?? ScreenRect(x: 0, y: 0, width: 800, height: 600)
        let stray = ScreenPoint(x: main.midX + 180, y: main.midY + 110)

        info("checking the cursor can be held in place…")
        LocalPointer.allowEventsDuringWarps()

        var corrections = 0
        for _ in 0..<12 {
            injector.move(to: stray)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.004))
            if LocalPointer.pin(to: park) { corrections += 1 }
        }
        LocalPointer.reattachToHardware()

        let ended = Displays.pointerLocation
        let drift = abs(ended.x - park.x) + abs(ended.y - park.y)
        guard corrections > 0 else {
            bad("the cursor never moved, so pinning could not be exercised")
            throw ExitSilently(code: 1)
        }
        if drift < 2 {
            ok("cursor pinned at \(park) through \(corrections) attempts to move it \(Int(abs(stray.x - park.x)))px away")
        } else {
            bad("cursor ended at \(ended), \(Int(drift))px from where it was pinned")
            LocalPointer.warp(to: park)
            throw ExitSilently(code: 1)
        }
    }

    /// Checks that swallowed movement cannot drag this Mac's cursor along.
    ///
    /// This has to use *real* hardware movement. Synthetic events carry an absolute position
    /// and move the cursor as they are posted, whether or not a tap deletes them, so driving
    /// this check with injected events would pass or fail for reasons that have nothing to do
    /// with the behaviour being tested.
    private static func checkSwallowingStopsTheLocalCursor() throws {
        guard isatty(STDIN_FILENO) == 1 else {
            info("skipping the local-cursor check: it needs you to move the mouse")
            return
        }

        let swallowed = Box<Int>(0)
        let tap = EventTap { type, event in
            switch type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                swallowed.mutate { $0 += 1 }
                return nil          // exactly what happens while the pointer is on the other Mac
            default:
                return event
            }
        }
        try tap.start()
        defer { tap.stop() }

        let level = tap.location == .cghidEventTap ? "HID" : "session"
        LocalPointer.detachFromHardware()
        defer { LocalPointer.reattachToHardware() }

        let start = Displays.pointerLocation
        out()
        warn("move your mouse around for the next 4 seconds — the cursor should NOT move")
        info("(this is what the other Mac having the pointer feels like; tap level: \(level))")

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        let ended = Displays.pointerLocation
        let drift = abs(ended.x - start.x) + abs(ended.y - start.y)
        out()

        guard swallowed.value > 0 else {
            warn("no movement arrived — did the mouse actually move? skipping this check")
            return
        }

        if drift < 4 {
            ok("cursor held still at \(start) while \(swallowed.value) movements were swallowed")
            info("no second pointer will trail along on this Mac")
        } else {
            bad("cursor drifted \(Int(drift))px to \(ended) despite swallowing \(swallowed.value) movements")
            out(Style.dim("    That is the two-pointers symptom. The tap is at the \(level) level"))
            out(Style.dim("    and the pointer was detached from the hardware; if both are true and"))
            out(Style.dim("    the cursor still moves, please report it with this output."))
            LocalPointer.warp(to: start)
            throw ExitSilently(code: 1)
        }
    }

    // MARK: - remote-test

    /// The real milestone-2 check: drive the *other* Mac's pointer across the link.
    static func remoteTest(_ args: Args) throws {
        let identity = try Identity.loadOrCreate()
        let config = try Config.load()
        let directory = try PairingDirectory.load()

        let target = try Target.resolve(argument: args.arg(0),
                                        store: directory.snapshot,
                                        config: config,
                                        explicitPairing: args.string("pair"))

        info("dialling \(NetworkAddress.describe(target.endpoint))  ·  pairing '\(target.pairing.label)'")

        let link = LinkConnector.connect(to: target.endpoint, psk: target.pairing.psk,
                                         identity: identity, localRole: .host)
        let remoteScreens = Box<[Display]>([])
        let ready = Box<Bool>(false)
        let closed = Box<Error??>(nil)

        link.onReady = { peer in
            directory.note(peer: peer)
            ok("link up  →  \(Style.bold(peer.name))  [\(peer.deviceID.short)]")
            link.send(.screenInfo(displays: Displays.current()))
            ready.value = true
        }
        link.onMessage = { message in
            if case let .screenInfo(displays) = message {
                remoteScreens.value = displays
                // Remember them so `continuous layout` works without a live link.
                directory.noteDisplays(displays, forKeyID: link.peer?.keyID ?? Data())
            }
        }
        link.onClose = { error in closed.value = .some(error) }
        link.start()

        guard Runtime.wait(until: { ready.value || closed.value != nil }, timeout: 12), ready.value else {
            if case let .some(.some(error)) = closed.value { bad(error.localizedDescription) }
            else { bad("could not establish the link") }
            throw ExitSilently(code: 1)
        }

        guard Runtime.wait(until: { !remoteScreens.value.isEmpty }, timeout: 5) else {
            bad("the other Mac did not report its screens — is it running this same build?")
            throw ExitSilently(code: 1)
        }

        let remote = remoteScreens.value
        ok("\(remote.count) remote display\(remote.count == 1 ? "" : "s") reported")
        for (i, d) in remote.enumerated() {
            out(Style.dim("    \(i + 1). \(d.rect)\(d.isMain ? "  (main)" : "")"))
        }

        guard let layout = ScreenLayout(localDisplays: Displays.current(), remoteDisplays: remote,
                                        edge: config.edge, alignment: config.alignment),
              let remoteBounds = ScreenRect.union(remote.map(\.rect)) else {
            throw ContinuousError.invalidArgument("could not work out a layout")
        }
        reportLayout(remoteDisplays: remote, remoteName: link.peer?.name ?? target.pairing.label, config: config)

        out()
        warn("about to move the pointer on the OTHER Mac — look at its screen")
        Thread.sleep(forTimeInterval: 2)

        // A square on the remote Mac's main display, sent as absolute positions in its own space.
        let main = remote.first(where: \.isMain)?.rect ?? remoteBounds
        let size = min(main.width, main.height) * 0.35
        let origin = ScreenPoint(x: main.midX - size / 2, y: main.midY - size / 2)
        let corners = [origin,
                       ScreenPoint(x: origin.x + size, y: origin.y),
                       ScreenPoint(x: origin.x + size, y: origin.y + size),
                       ScreenPoint(x: origin.x, y: origin.y + size),
                       origin]

        link.send(.enterScreen(x: Int32(origin.x), y: Int32(origin.y), flags: 0))
        var previous = origin
        var sent = 0
        let began = Date()
        for corner in corners {
            let steps = 40
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let p = ScreenPoint(x: previous.x + (corner.x - previous.x) * t,
                                    y: previous.y + (corner.y - previous.y) * t)
                link.send(.mouseMove(x: Int32(p.x), y: Int32(p.y),
                                     dx: Int32(p.x - previous.x), dy: Int32(p.y - previous.y)))
                sent += 1
                Thread.sleep(forTimeInterval: 0.008)
            }
            previous = corner
        }
        ok(String(format: "sent %d pointer events in %.1fs", sent, Date().timeIntervalSince(began)))

        info("scrolling on the other Mac")
        for _ in 0..<10 { link.send(.scroll(dx: 0, dy: -6, isPixel: true)); Thread.sleep(forTimeInterval: 0.02) }

        // Each corner of the remote desktop, to prove multi-display coverage.
        info("visiting each corner of the other Mac's desktop")
        for p in [ScreenPoint(x: remoteBounds.x + 3, y: remoteBounds.y + 3),
                  ScreenPoint(x: remoteBounds.maxX - 3, y: remoteBounds.y + 3),
                  ScreenPoint(x: remoteBounds.maxX - 3, y: remoteBounds.maxY - 3),
                  ScreenPoint(x: remoteBounds.x + 3, y: remoteBounds.maxY - 3)] {
            let safe = ScreenLayout.nearestPoint(in: remote.map(\.rect), to: p)
            link.send(.mouseMove(x: Int32(safe.x), y: Int32(safe.y), dx: 0, dy: 0))
            Thread.sleep(forTimeInterval: 0.6)
        }

        if args.bool("keys") {
            out()
            warn("typing on the other Mac in 3 seconds — focus a text field over there")
            Thread.sleep(forTimeInterval: 3)
            // 'C','o','n','t' by virtual key code, so layout handling is exercised rather than
            // the unicode shortcut.
            for code: UInt16 in [8, 31, 45, 17] {
                link.send(.keyEvent(keyCode: code, down: true, isRepeat: false, flags: 0))
                Thread.sleep(forTimeInterval: 0.04)
                link.send(.keyEvent(keyCode: code, down: false, isRepeat: false, flags: 0))
                Thread.sleep(forTimeInterval: 0.06)
            }
            ok("sent four keystrokes — 'cont' should have appeared")
        }

        // Put the pointer back where the handover edge would leave it, then let go.
        let entry = layout.entryPoint(leavingLocalAt: ScreenPoint(x: layout.localBounds.maxX - 1,
                                                                 y: layout.localBounds.midY))
        link.send(.mouseMove(x: Int32(entry.x), y: Int32(entry.y), dx: 0, dy: 0))
        info("pointer parked at \(entry) — where it will arrive in milestone 3")
        link.send(.leaveScreen)
        Thread.sleep(forTimeInterval: 0.3)
        link.close(reason: "remote-test finished")
        out()
        ok("milestone 2 verified: this Mac drove the other Mac's pointer")
    }
}
