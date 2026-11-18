import Foundation
import CoreGraphics
import EdgeCore

/// Milestone 3: captures this Mac's keyboard and pointer and hands them to the other Mac when
/// the pointer walks off the shared edge.
///
/// ## The safety problem
///
/// While the pointer is on the other Mac this session *swallows* every input event. If it kept
/// doing that after something went wrong, this Mac would be left with no keyboard and no
/// pointer, and the only way out would be the power button. So there are four independent ways
/// back to local control, and every one of them is a path that cannot itself fail:
///
/// 1. the link closing,
/// 2. the heartbeat going quiet for a few seconds,
/// 3. the escape chord (all four modifiers together),
/// 4. the tap being disabled by the system.
///
/// Events are only ever swallowed while the link is up *and* a layout is known. Any other
/// state passes everything straight through.
final class SharingSession {
    enum Mode { case local, remote }

    /// Holding Command, Option, Control and Shift at once returns the pointer here. Nothing
    /// sensible uses that combination, and it is reachable with one hand without looking.
    static let escapeChord: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    /// With no pong for this long, assume the other Mac is gone and take the pointer back.
    static let silenceTimeout: TimeInterval = 4

    private let config: Config
    private let remoteName: String
    private let lock = NSLock()

    private var tap: EventTap?
    private weak var link: SecureLink?
    /// All the "where is the pointer and may we swallow this" rules live here, as a plain
    /// value type with its own tests.
    private var router = PointerRouter()
    private var lastHeardFrom = Date()
    private var capture = LocalPointer.CaptureState()
    private var forwarded = 0
    /// Where this Mac's cursor was parked when the pointer left.
    private var parkedAt: ScreenPoint?
    private var driftCorrections = 0
    /// Buttons currently held down on this Mac's own mouse.
    private var heldButtons: Set<MouseButtonID> = []
    /// Optional belt-and-braces re-parking, off by default — see `startHolding`.
    private var holdTimer: DispatchSourceTimer?
    /// Largest distance the cursor strayed from its parking spot during this trip.
    private var maxDrift: Double = 0
    private var driftSamples = 0
    /// Samples the cursor far faster than the run loop ticks.
    ///
    /// At 10 Hz a sampler cannot distinguish a cursor that never moved from one that a timer
    /// keeps putting back, which is how the previous diagnosis went wrong. 1 ms can.
    private var driftTimer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private let holdQueue = DispatchQueue(label: "app.edge.cursor-hold")
    /// Files found on the drag pasteboard as the pointer left, waiting to be sent.
    private var pendingDragFiles: [URL] = []
    /// The transfer in progress, kept alive while it runs.
    private var sender: FileSender?
    /// Set when a file drag was taken over, so the mouse-up that ends it is not forwarded to
    /// the other Mac as a stray click on whatever is under the pointer there.
    private var swallowNextMouseUp = false
    /// Throttles the pasteboard peek; reading it on every movement is a round trip per event.
    private var lastDragPeek = Date.distantPast

    var onModeChange: ((Mode) -> Void)?
    /// Called when files start crossing, so the session can say so.
    var onFilesSent: ((Int, String?) -> Void)?
    /// Whether this Mac will carry dragged files at all.
    var filesEnabled = true
    /// Whether the other Mac said it would accept them. Until it has, a file drag stops at
    /// the edge exactly as a window drag does — better than crossing into silence.
    var peerAcceptsFiles = false

    init(config: Config, remoteName: String) {
        self.config = config
        self.remoteName = remoteName
        router.edgePressureThreshold = config.edgePressure
        filesEnabled = config.fileSharing
    }

    // MARK: - Lifecycle

    func start() throws {
        let tap = EventTap { [weak self] type, event in
            guard let self else { return event }
            return self.handle(type: type, event: event)
        }
        try tap.start()
        self.tap = tap

        // Tell the system this process is latency-critical.
        //
        // Run from a terminal it inherits the foreground app's treatment and feels fine. Run
        // as a child of a menu-bar accessory it is just another background process, so App Nap
        // throttles it and coalesces its timers — which arrives as a visibly laggy pointer on
        // the other Mac. This is the documented way to opt out, and it is the difference
        // between the two front ends feeling the same.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "forwarding keyboard and pointer input to another Mac")

        LocalPointer.installCrashSafety()
        // Ask for background cursor control once, up front, so a failure is reported at
        // start-up rather than discovered the first time the pointer crosses over.
        if !LocalPointer.enableBackgroundCursorControl() {
            Log.warn("this Mac will not let a background process hide the cursor; "
                     + "it will stay visible (but still) while the pointer is away")
        }
        // Must happen before the first correction, or each one would deafen us for 250 ms.
        LocalPointer.allowEventsDuringWarps()
    }

    func stop() {
        returnToLocal(reason: "stopping")
        tap?.stop()
        tap = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func attach(link: SecureLink, layout: ScreenLayout?) {
        lock.lock()
        self.link = link
        if let layout { router.layout = layout }
        lastHeardFrom = Date()
        lock.unlock()
    }

    /// A monitor just moved between the two Macs, or a display was rearranged.
    func update(layout: ScreenLayout) {
        lock.lock()
        let wasRemote = router.isRemote
        let destination = router.replaceLayout(layout)
        let currentLink = link
        lock.unlock()

        if wasRemote {
            finishReturn(to: destination, link: currentLink, reason: "the screen arrangement changed")
        }
    }

    func noteTraffic() {
        lock.lock(); lastHeardFrom = Date(); lock.unlock()
    }

    func detach(reason: String) {
        returnToLocal(reason: reason)
        lock.lock(); link = nil; lock.unlock()
    }

    /// Called from the run loop, about ten times a second.
    func checkLiveness() {
        lock.lock()
        let remote = router.isRemote
        let stale = remote && Date().timeIntervalSince(lastHeardFrom) > Self.silenceTimeout
        let parked = parkedAt
        lock.unlock()

        if stale {
            returnToLocal(reason: "the other Mac stopped responding")
            return
        }

        // Measure rather than correct. If the cursor is straying, that is worth knowing
        // precisely; correcting it from here was what masked the real problem.
        guard remote, let parked else { return }
        let actual = LocalPointer.liveLocation
        let drift = abs(actual.x - parked.x) + abs(actual.y - parked.y)
        if drift > maxDrift {
            lock.lock(); maxDrift = drift; lock.unlock()
            if drift > 4 {
                Log.warn(String(format: "this Mac's cursor has strayed %.0fpx from where it was parked", drift))
            }
        }
    }

    var isRemote: Bool { lock.lock(); defer { lock.unlock() }; return router.isRemote }

    private var captureSummary: String { lock.lock(); defer { lock.unlock() }; return capture.summary }

    private var hideAttempts: Int { lock.lock(); defer { lock.unlock() }; return capture.hideRounds }

    /// True once the event tap is installed. It stays installed across reconnections: with no
    /// link attached it swallows nothing, so there is no reason to tear it down and risk
    /// failing to get it back.
    var isCapturing: Bool { tap != nil }

    var forwardedCount: Int { lock.lock(); defer { lock.unlock() }; return forwarded }

    // MARK: - The tap handler

    private func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        // Events this app posted itself pass straight through, in either mode. The only ones
        // are the Escape and mouse-up that cancel a drag this Mac has handed over, and they
        // are meant for the application here, never for the other Mac.
        if SyntheticEvent.isOurs(event) { return event }

        // The escape chord is checked before anything else, in both modes, so it works even
        // if the logic below is wrong.
        if type == .flagsChanged, event.flags.contains(Self.escapeChord) {
            if isRemote { returnToLocal(reason: "escape chord") }
            return event
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            returnToLocal(reason: "the system disabled the event tap")
            return event
        }

        lock.lock()
        let currentLink = link
        let haveLayout = router.layout != nil
        let remote = router.isRemote
        lock.unlock()

        // No link or no known arrangement: never swallow anything.
        guard haveLayout, let currentLink else { return event }

        // A held button means a drag is in progress on this Mac. Crossing mid-drag strands
        // whatever you were dragging, so note the state and let the router refuse.
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let b = event.mouseButtonID {
                lock.lock(); heldButtons.insert(b); router.allowCrossing = false; lock.unlock()
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if let b = event.mouseButtonID {
                lock.lock()
                heldButtons.remove(b)
                router.allowCrossing = heldButtons.isEmpty
                let swallow = b == .left && swallowNextMouseUp
                if swallow { swallowNextMouseUp = false }
                lock.unlock()
                // The button that was held for a file drag. The drag ended here when the
                // files were taken over; releasing it must not also click over there.
                if swallow { return nil }
            }
        default:
            break
        }

        let isMovement = type == .mouseMoved || type == .leftMouseDragged
            || type == .rightMouseDragged || type == .otherMouseDragged

        if isMovement {
            let location = ScreenPoint(x: Double(event.location.x), y: Double(event.location.y))
            // A drag leaning on the shared edge: if it is carrying files, let it through.
            // Window drags and text selections still stop at the edge, which is what you
            // want — only files have anywhere to go on the other Mac.
            if !remote { considerFileDrag(at: location) }
            lock.lock()
            let decision = router.pointerMoved(localLocation: location, delta: event.pointerDelta)
            lock.unlock()

            switch decision {
            case .passThrough:
                return event
            case let .cross(entry):
                beginRemote(entry: entry, departure: location, link: currentLink,
                            flags: event.flags.rawValue)
                return nil
            case let .forward(remotePoint):
                let delta = event.pointerDelta
                currentLink.send(.mouseMove(x: Int32(remotePoint.x), y: Int32(remotePoint.y),
                                            dx: Int32(delta.x), dy: Int32(delta.y)))

                // Nothing else happens here, deliberately.
                //
                // This callback sits inside the window server's own event pipeline, and a
                // synchronous call back into it — warping the cursor, say — is enough to make
                // events slip through unswallowed. `cursor-doctor` measured a callback that
                // only counts and deletes: 447 movements, cursor held at a single position.
                // Deleting the event is what holds the cursor still. Anything added here can
                // only take that away.
                lock.lock(); forwarded += 1; lock.unlock()
                return nil
            case let .comeBack(local):
                finishReturn(to: local, link: currentLink, reason: "pointer came back")
                return nil
            }
        }

        guard remote else { return event }
        forward(type: type, event: event, link: currentLink)
        return nil   // this Mac must not also act on it
    }

    // MARK: - Files

    /// Decides whether the drag now pressing on the edge is one that can cross.
    ///
    /// Only called while the pointer is still on this Mac, and only while a button is down.
    /// The pasteboard read is the expensive part — a round trip to the pasteboard server — so
    /// it happens at most a few times a second and only once the pointer is actually at the
    /// edge, which is far rarer than a movement.
    private func considerFileDrag(at location: ScreenPoint) {
        lock.lock()
        let held = !heldButtons.isEmpty
        let alreadyAllowed = router.allowCrossing
        let atEdge = router.layout?.isAtTransferEdge(location) ?? false
        lock.unlock()

        guard filesEnabled, peerAcceptsFiles, held, !alreadyAllowed, atEdge else { return }
        guard Date().timeIntervalSince(lastDragPeek) > 0.15 else { return }
        lastDragPeek = Date()

        let files = DraggedFiles.current()
        guard !files.isEmpty else { return }

        lock.lock()
        pendingDragFiles = files
        router.allowCrossing = true
        lock.unlock()
        Log.debug("a drag of \(files.count) file(s) is pressing on the edge — letting it cross")
    }

    /// Hands the files over and ends the drag on this Mac.
    private func startFileTransfer(link: SecureLink, releasingAt point: ScreenPoint) {
        lock.lock()
        let files = pendingDragFiles
        pendingDragFiles = []
        guard !files.isEmpty else { lock.unlock(); return }
        swallowNextMouseUp = true
        heldButtons.removeAll()
        lock.unlock()

        // Cancel the drag here before anything is sent. The source application is holding a
        // drag whose mouse-up is about to be swallowed, and left alone it stays holding it.
        DraggedFiles.cancelLocalDrag(releasingAt: point)

        let sender = FileSender(link: link)
        sender.onStarted = { [weak self] count, bytes in
            Log.info("sending \(count) file(s), \(bytes) bytes")
            self?.onFilesSent?(count, nil)
        }
        sender.onFinished = { [weak self] reason in
            guard let self else { return }
            self.lock.lock(); self.sender = nil; self.lock.unlock()
            if let reason { self.onFilesSent?(0, reason) }
        }
        lock.lock(); self.sender = sender; lock.unlock()
        if !sender.start(urls: files) {
            lock.lock(); self.sender = nil; lock.unlock()
            onFilesSent?(0, "nothing in that drag could be sent")
        }
    }

    /// Asks the other Mac whether the drag coming back carries files.
    ///
    /// Only that Mac can see its own drag pasteboard, and it is about to lose the drag: the
    /// moment the pointer leaves, the injected button is released over there. So the question
    /// goes first, ahead of the message that releases it.
    private func requestFilesFromPeer(_ link: SecureLink?) {
        lock.lock()
        let held = !heldButtons.isEmpty
        lock.unlock()
        guard filesEnabled, peerAcceptsFiles, held, let link else { return }
        link.send(.fileRequest)
    }

    // MARK: - Crossing over

    private func beginRemote(entry: ScreenPoint, departure: ScreenPoint,
                             link: SecureLink, flags: UInt64) {
        lock.lock(); lastHeardFrom = Date(); lock.unlock()

        link.send(.enterScreen(x: Int32(entry.x), y: Int32(entry.y), flags: flags))

        // Before the cursor is hidden and the hardware detached: both of those make the
        // events that end the drag here impossible to deliver.
        startFileTransfer(link: link, releasingAt: departure)

        // One call, because the order inside it is the thing that was wrong for four
        // attempts: park, then hide, then uncouple — hiding re-couples the pointer, so
        // uncoupling has to come last.
        capture = LocalPointer.beginCapture(parkingAt: departure)
        lock.lock(); parkedAt = departure; driftCorrections = 0; maxDrift = 0; lock.unlock()
        startHolding(at: departure)
        startWatchingDrift(from: departure)
        Log.debug("pointer left this Mac at \(departure) → arrived at \(entry) on the other "
                  + "(\(capture.summary))")
        if !capture.hidden {
            Log.warn("could not hide this Mac's cursor; it will sit parked at the edge instead")
        }

        onModeChange?(.remote)
    }

    /// Re-parks the cursor on a timer, off the tap's thread. Off unless asked for.
    ///
    /// Deleting the movement is what actually holds the cursor still, and it does so
    /// completely. This exists for the case where some Mac, some day, turns out to need it —
    /// `edge config set holdLocalPointer true`. It runs on its own queue rather than in
    /// the tap callback, because that is where the harm was.
    /// Watches where this Mac's cursor really is, without touching it.
    private func startWatchingDrift(from point: ScreenPoint) {
        driftTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: holdQueue)
        // 50 Hz, not the 1 kHz this started at. Reading the pointer is a round trip to the
        // window server, and a thousand of those a second competes with the event tap for the
        // very thing being measured. Twenty milliseconds still catches any drift worth seeing.
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let live = LocalPointer.liveLocation
            let drift = abs(live.x - point.x) + abs(live.y - point.y)

            self.lock.lock()
            self.driftSamples += 1
            if drift > self.maxDrift { self.maxDrift = drift }
            self.lock.unlock()

            // Something else in the system can un-hide the cursor: AppKit reconsiders it in
            // any process that touches its own interface, and the menu-bar front end is one
            // such process sitting right there. Notice within a frame and put it back, rather
            // than leaving a pointer parked on a screen nobody is using.
            // Not gated on the first hide having succeeded: it sometimes does not, and
            // giving up then is exactly what strands a pointer on the screen just left.
            guard LocalPointer.isCursorVisible == true else { return }
            self.lock.lock()
            LocalPointer.reassertHidden(&self.capture)
            let total = self.capture.hideRounds
            self.lock.unlock()
            if total == 2 || total % 50 == 0 {
                Log.debug("something re-showed this Mac's cursor; hidden again (\(total) times)")
            }
        }
        driftTimer = timer
        timer.resume()
    }

    private func stopWatchingDrift() {
        driftTimer?.cancel()
        driftTimer = nil
    }

    private func startHolding(at point: ScreenPoint) {
        guard config.holdLocalPointer else { return }
        holdTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: holdQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
        timer.setEventHandler { LocalPointer.hold(at: point) }
        holdTimer = timer
        timer.resume()
    }

    private func stopHolding() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    private func returnToLocal(reason: String) {
        lock.lock()
        guard router.isRemote else { lock.unlock(); return }
        let destination = router.forceLocal()
        let currentLink = link
        lock.unlock()
        finishReturn(to: destination, link: currentLink, reason: reason)
    }

    /// The one place that restores local control. Every route back goes through it, so none
    /// of them can forget to re-attach the hardware or un-hide the cursor.
    private func finishReturn(to destination: ScreenPoint?, link: SecureLink?, reason: String) {
        // First thing, before anything can warp the cursor back to the parking spot again.
        stopHolding()
        stopWatchingDrift()
        // Ahead of leaveScreen, which is what releases the drag on the other Mac.
        requestFilesFromPeer(link)
        link?.send(.leaveScreen)

        LocalPointer.endCapture(capture, restoringTo: destination)
        capture = LocalPointer.CaptureState()
        lock.lock()
        parkedAt = nil
        let corrections = driftCorrections
        let moves = forwarded
        driftCorrections = 0
        lock.unlock()
        _ = corrections
        lock.lock()
        let strayed = maxDrift
        let samples = driftSamples
        maxDrift = 0
        driftSamples = 0
        lock.unlock()

        let summary = String(format: "cursor strayed at most %.0fpx over %d samples "
                             + "(%d movements forwarded; tap %@, %@, re-hidden %d time(s))",
                             strayed, samples, moves,
                             tap?.location == .cghidEventTap ? "HID" : "session",
                             captureSummary, max(0, hideAttempts - 1))
        // Surfaced rather than buried: this is the number that says whether the second
        // cursor is still happening, and it comes from the real session rather than a
        // reconstruction of it.
        if strayed > 8 {
            warn("this Mac's cursor moved while the pointer was away — " + summary)
        } else {
            Log.debug(summary)
        }

        Log.debug("pointer back on this Mac (\(reason))")
        onModeChange?(.local)
    }

    // MARK: - Forwarding

    private func forward(type: CGEventType, event: CGEvent, link: SecureLink) {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            guard let button = event.mouseButtonID else { return }
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            lock.lock(); let point = router.currentRemotePoint(); lock.unlock()
            guard let point else { return }
            link.send(.mouseButton(button: button, down: down,
                                   clickCount: UInt8(clamping: event.clickCount),
                                   x: Int32(point.x), y: Int32(point.y)))

        case .scrollWheel:
            let (dx, dy) = event.scrollDelta
            link.send(.scroll(dx: dx, dy: dy, isPixel: event.isContinuousScroll))

        case .keyDown, .keyUp:
            link.send(.keyEvent(keyCode: event.keyCode, down: type == .keyDown,
                                isRepeat: event.isAutorepeat, flags: event.flags.rawValue))

        case .flagsChanged:
            link.send(.flagsChanged(flags: event.flags.rawValue))

        default:
            break
        }
    }
}
