import Foundation
import CoreGraphics
import ContinuousCore

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
    private var cursorHidden = false
    private var pointerDetached = false
    private var forwarded = 0
    /// Where this Mac's cursor was parked when the pointer left.
    private var parkedAt: ScreenPoint?
    private var driftCorrections = 0
    /// Buttons currently held down on this Mac's own mouse.
    private var heldButtons: Set<MouseButtonID> = []

    var onModeChange: ((Mode) -> Void)?

    init(config: Config, remoteName: String) {
        self.config = config
        self.remoteName = remoteName
        router.edgePressureThreshold = config.edgePressure
    }

    // MARK: - Lifecycle

    func start() throws {
        let tap = EventTap { [weak self] type, event in
            guard let self else { return event }
            return self.handle(type: type, event: event)
        }
        try tap.start()
        self.tap = tap
        LocalPointer.installCrashSafety()
        // Must happen before the first correction, or each one would deafen us for 250 ms.
        LocalPointer.allowEventsDuringWarps()
    }

    func stop() {
        returnToLocal(reason: "stopping")
        tap?.stop()
        tap = nil
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

        // Second line of defence, for the case where no movement events are arriving at all
        // and so the per-event pinning never runs.
        guard remote, let parked else { return }
        if LocalPointer.pin(to: parked) {
            lock.lock(); driftCorrections += 1; lock.unlock()
        }
    }

    var isRemote: Bool { lock.lock(); defer { lock.unlock() }; return router.isRemote }

    /// True once the event tap is installed. It stays installed across reconnections: with no
    /// link attached it swallows nothing, so there is no reason to tear it down and risk
    /// failing to get it back.
    var isCapturing: Bool { tap != nil }

    var forwardedCount: Int { lock.lock(); defer { lock.unlock() }; return forwarded }

    // MARK: - The tap handler

    private func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
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
                lock.unlock()
            }
        default:
            break
        }

        let isMovement = type == .mouseMoved || type == .leftMouseDragged
            || type == .rightMouseDragged || type == .otherMouseDragged

        if isMovement {
            let location = ScreenPoint(x: Double(event.location.x), y: Double(event.location.y))
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

                // Hold this Mac's own cursor still. Swallowing the event and detaching the
                // pointer both report success and neither actually stops it, so the position
                // is checked and corrected on every single movement instead.
                lock.lock()
                forwarded += 1
                let parked = parkedAt
                lock.unlock()
                if let parked, LocalPointer.pin(to: parked) {
                    lock.lock(); driftCorrections += 1; lock.unlock()
                }
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

    // MARK: - Crossing over

    private func beginRemote(entry: ScreenPoint, departure: ScreenPoint,
                             link: SecureLink, flags: UInt64) {
        lock.lock(); lastHeardFrom = Date(); lock.unlock()

        link.send(.enterScreen(x: Int32(entry.x), y: Int32(entry.y), flags: flags))

        // Stop the hardware from moving our own pointer; deltas still reach the tap.
        // Order matters here. Park the cursor first, *then* detach it from the hardware:
        // warping is documented to re-couple them, so detaching first and warping second
        // silently undoes the detach — which is one way to end up with a second pointer
        // sliding around this Mac while the real one is on the other.
        LocalPointer.warp(to: departure)
        pointerDetached = LocalPointer.detachFromHardware()
        cursorHidden = LocalPointer.hide()
        lock.lock(); parkedAt = departure; driftCorrections = 0; lock.unlock()
        Log.debug("pointer left this Mac at \(departure) → arrived at \(entry) on the other")
        if !cursorHidden {
            Log.debug("could not hide the local cursor; it will sit parked at the edge instead")
        }

        onModeChange?(.remote)
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
        link?.send(.leaveScreen)

        if pointerDetached { LocalPointer.reattachToHardware(); pointerDetached = false }
        if cursorHidden { LocalPointer.show(); cursorHidden = false }
        if let destination { LocalPointer.warp(to: destination) }
        lock.lock()
        parkedAt = nil
        let corrections = driftCorrections
        let moves = forwarded
        driftCorrections = 0
        lock.unlock()
        if corrections > 0 {
            // Expected to be most of them: see the note on LocalPointer.
            Log.debug("held this Mac's cursor still through \(corrections) of \(moves) movements "
                      + "(tap: \(tap?.location == .cghidEventTap ? "HID" : "session"), detach reported \(pointerDetached ? "success" : "failure"))")
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
