import Foundation
import AppKit
import CoreGraphics

/// A `CGEventTap` on the Mac whose keyboard and mouse are being shared.
///
/// The tap is inserted at the head of the chain in *active* mode, which means the handler may
/// return `nil` to swallow an event entirely. That is the whole trick: while the pointer is on
/// the other Mac, every key and every movement is consumed here and forwarded, so this Mac
/// sees nothing and the other one behaves as though the keyboard were plugged into it.
///
/// ## Why the HID level and not the session level
///
/// `.cgSessionEventTap` is too late. By the time an event reaches it the window server has
/// *already* moved the pointer, so swallowing it stops applications reacting but leaves the
/// cursor sliding around the screen — two pointers moving at once, one on each Mac.
///
/// `.cghidEventTap` is the point where events enter the window server. Deleting a movement
/// there means the local cursor never moves in the first place, which is the only way to get
/// this right. It is also what every other tool in this category does.
///
/// Swallowing input is also the dangerous part. A tap that keeps consuming after the link has
/// gone would leave this Mac with no keyboard and no pointer, so every path that can fail has
/// to fall back to passing events through — see `SharingSession`.
public final class EventTap {
    /// Return the event to let it through, a different event to replace it, or `nil` to
    /// swallow it. Runs on the thread whose run loop the tap was added to.
    public typealias Handler = (CGEventType, CGEvent) -> CGEvent?

    public enum StartFailure: LocalizedError {
        case notPermitted
        case couldNotCreate

        public var errorDescription: String? {
            switch self {
            case .notPermitted:
                return "macOS refused to create the event tap — Input Monitoring and Accessibility are both required"
            case .couldNotCreate:
                return "could not create the event tap"
            }
        }
    }

    private let handler: Handler
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Everything needed to drive another Mac, and nothing else.
    public static var defaultMask: CGEventMask {
        let types: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel,
            .keyDown, .keyUp, .flagsChanged,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
    }

    /// Where the tap was actually installed. `.cgSessionEventTap` means the HID level was
    /// refused and the caller needs to compensate — see `LocalPointer.detachFromHardware`.
    public private(set) var location: CGEventTapLocation = .cghidEventTap

    public func start(mask: CGEventMask? = nil) throws {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()

            // macOS disables a tap whose handler was too slow, and the only way back is to
            // turn it on again. Dropping this case would mean input silently stops being
            // forwarded with no indication why.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Log.warn("event tap was disabled by the system (\(type == .tapDisabledByTimeout ? "timeout" : "user input")) — re-enabling")
                tap.setEnabled(true)
                tap.handler(type, event)
                return Unmanaged.passUnretained(event)
            }

            guard let result = tap.handler(type, event) else { return nil }
            return Unmanaged.passUnretained(result)
        }

        func create(at location: CGEventTapLocation) -> CFMachPort? {
            CGEvent.tapCreate(tap: location,
                              place: .headInsertEventTap,
                              options: .defaultTap,
                              eventsOfInterest: mask ?? Self.defaultMask,
                              callback: callback,
                              userInfo: refcon)
        }

        var chosen = CGEventTapLocation.cghidEventTap
        var created = create(at: chosen)
        if created == nil {
            // Some managed configurations refuse a HID-level tap. The session level still
            // works for forwarding; the caller then has to stop the local cursor by other
            // means, which is why the location is exposed.
            Log.warn("could not tap at the HID level; falling back to the session level — the local cursor will need to be detached separately")
            chosen = .cgSessionEventTap
            created = create(at: chosen)
        }

        guard let port = created else {
            // tapCreate returns nil for a missing permission as well as for bad arguments;
            // the permission is overwhelmingly the likely cause.
            throw Permissions.inputMonitoring().isGranted && Permissions.accessibility().isGranted
                ? StartFailure.couldNotCreate
                : StartFailure.notPermitted
        }
        self.location = chosen

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        self.port = port
        self.runLoopSource = source
        Log.debug("event tap installed at the \(chosen == .cghidEventTap ? "HID" : "session") level")
    }

    public func setEnabled(_ enabled: Bool) {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: enabled)
    }

    public var isEnabled: Bool {
        guard let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    public func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let port { CFMachPortInvalidate(port) }
        runLoopSource = nil
        port = nil
    }

    deinit { stop() }
}

/// Reading the fields of a captured event, in one place so the sharing logic stays readable.
public extension CGEvent {
    var pointerDelta: ScreenPoint {
        ScreenPoint(x: Double(getIntegerValueField(.mouseEventDeltaX)),
                    y: Double(getIntegerValueField(.mouseEventDeltaY)))
    }

    var clickCount: Int { Int(getIntegerValueField(.mouseEventClickState)) }
    var keyCode: UInt16 { UInt16(truncatingIfNeeded: getIntegerValueField(.keyboardEventKeycode)) }
    var isAutorepeat: Bool { getIntegerValueField(.keyboardEventAutorepeat) != 0 }

    /// Trackpads and Magic Mice report smooth pixel scrolling; a wheel mouse reports lines.
    /// Forwarding the wrong one makes scrolling either glacial or absurdly fast.
    var isContinuousScroll: Bool { getIntegerValueField(.scrollWheelEventIsContinuous) != 0 }

    var scrollDelta: (dx: Int32, dy: Int32) {
        if isContinuousScroll {
            return (Int32(truncatingIfNeeded: getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
                    Int32(truncatingIfNeeded: getIntegerValueField(.scrollWheelEventPointDeltaAxis1)))
        }
        return (Int32(truncatingIfNeeded: getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                Int32(truncatingIfNeeded: getIntegerValueField(.scrollWheelEventDeltaAxis1)))
    }

    var mouseButtonID: MouseButtonID? {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: return .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return .right
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return MouseButtonID(rawValue: UInt8(truncatingIfNeeded: getIntegerValueField(.mouseEventButtonNumber)))
                ?? .middle
        default: return nil
        }
    }
}

/// What this Mac does with its own pointer while the other Mac has it.
///
/// Three calls in a specific order, and the order is the entire difficulty:
///
/// 1. **Park** the cursor where it left.
/// 2. **Hide** it — which requires telling the window server that a background process is
///    allowed to, or `CGDisplayHideCursor` returns success and does nothing at all.
/// 3. **Uncouple** it from the mouse, *last*, because hiding re-couples it.
///
/// Doing (3) before (2) leaves the pointer coupled, so it follows your hand around a screen
/// you are not using. That is the second cursor, and it is why `beginCapture` exists as one
/// function rather than three calls a caller could order wrongly.
public enum LocalPointer {

    /// Everything `beginCapture` did, so `endCapture` can undo exactly that much and the
    /// caller can report what worked.
    public struct CaptureState: Sendable {
        public var backgroundControl = false
        public var hidden = false
        public var uncoupled = false
        /// What the window server says, rather than what the hide call returned.
        /// `nil` when it could not be asked.
        public var confirmedHidden: Bool?
        /// How many unbalanced hides this process owns. `CGDisplayHideCursor` is reference
        /// counted, so every one of them needs a matching show or the cursor never returns.
        public var hideCount = 0
        public var parkedAt = ScreenPoint(x: 0, y: 0)

        public init() {}

        public var summary: String {
            let confirmation: String
            switch confirmedHidden {
            case .some(true):  confirmation = "cursor confirmed hidden"
            case .some(false): confirmation = "CURSOR STILL VISIBLE"
            case nil:          confirmation = "visibility unverifiable"
            }
            return "background-control \(backgroundControl ? "ok" : "unavailable"), "
                + "hide \(hidden ? "ok" : "failed"), uncouple \(uncoupled ? "ok" : "failed"), "
                + confirmation
        }
    }

    // MARK: - Private window-server SPI

    private typealias CGSConnectionID = Int32
    private typealias DefaultConnectionFn = @convention(c) () -> CGSConnectionID
    private typealias SetConnectionPropertyFn =
        @convention(c) (CGSConnectionID, CGSConnectionID, CFString, CFTypeRef) -> CGError

    /// Grants this process permission to change the cursor while it is not the frontmost app.
    ///
    /// `CGDisplayHideCursor` is documented to apply "while the application is active", and a
    /// background tool never is — so it returns `kCGErrorSuccess` and the cursor stays exactly
    /// where it was, visible. The window server exposes a connection property that lifts that
    /// restriction. It is private, so it is resolved at runtime and treated as optional:
    /// without it the pointer is still uncoupled and still stops moving, it is merely visible.
    @discardableResult
    public static func enableBackgroundCursorControl() -> Bool {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let propertySymbol = dlsym(handle, "CGSSetConnectionProperty") else {
            Log.debug("window-server cursor SPI unavailable; the local cursor will stay visible")
            return false
        }
        let connection = unsafeBitCast(connectionSymbol, to: DefaultConnectionFn.self)()
        let setProperty = unsafeBitCast(propertySymbol, to: SetConnectionPropertyFn.self)
        let result = setProperty(connection, connection,
                                 "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if result != .success {
            Log.debug("SetsCursorInBackground refused (\(result.rawValue))")
        }
        return result == .success
    }

    private typealias CursorIsVisibleFn = @convention(c) () -> boolean_t

    /// Resolved once. This is checked many times a second while the pointer is away, and
    /// `dlsym` on every call would be a silly way to spend a window-server round trip.
    private static let cursorIsVisibleFn: CursorIsVisibleFn? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(symbol, to: CursorIsVisibleFn.self)
    }()

    /// Whether the window server currently considers the cursor visible.
    ///
    /// Withdrawn from the SDK years ago but still present in CoreGraphics, and the only way
    /// to tell a hide that worked from a hide that returned success and did nothing — which
    /// is the difference between one pointer and two. `nil` if it cannot be resolved.
    public static var isCursorVisible: Bool? {
        guard let fn = cursorIsVisibleFn else { return nil }
        return fn() != 0
    }

    // MARK: - Capture

    public static func beginCapture(parkingAt point: ScreenPoint) -> CaptureState {
        var state = CaptureState()
        state.parkedAt = point

        allowEventsDuringWarps()
        warp(to: point)

        state.backgroundControl = enableBackgroundCursorControl()
        // Every display, not just the main one. The cursor is parked wherever it left, which
        // on a Mac with an external monitor is usually not the main display — and hiding a
        // display the cursor is not on leaves it sitting there in plain sight.
        state.hideCount = hideOnAllDisplays()
        state.hidden = state.hideCount > 0

        // Last, deliberately: hiding the cursor re-couples it to the mouse.
        state.uncoupled = CGAssociateMouseAndMouseCursorPosition(0) == .success

        // `CGDisplayHideCursor` reports success whether or not it was allowed to do
        // anything, so believe the window server rather than the return code.
        state.confirmedHidden = isCursorVisible.map { !$0 }
        return state
    }

    private static func hideOnAllDisplays() -> Int {
        var hidden = 0
        for id in activeDisplayIDs() where CGDisplayHideCursor(id) == .success { hidden += 1 }
        return hidden
    }

    /// Hides the cursor again if something else put it back. Balanced by `endCapture`.
    ///
    /// Deliberately not conditional on the first attempt having worked. Hiding occasionally
    /// fails — a display mid-reconfiguration, a busy window server — and giving up after one
    /// failure is what strands a pointer on the screen you have just left.
    public static func reassertHidden(_ state: inout CaptureState) {
        enableBackgroundCursorControl()
        let hidden = hideOnAllDisplays()
        guard hidden > 0 else { return }
        state.hideCount += hidden
        state.hidden = true
    }

    public static func endCapture(_ state: CaptureState, restoringTo point: ScreenPoint?) {
        if state.hideCount > 0 {
            enableBackgroundCursorControl()
            // One show per hide: the count is per-process and unbalancing it would leave this
            // Mac with no cursor at all until the next login.
            for _ in 0..<state.hideCount {
                if CGDisplayShowCursor(CGMainDisplayID()) != .success {
                    Log.error("could not show the cursor again")
                    break
                }
            }
        }
        if CGAssociateMouseAndMouseCursorPosition(1) != .success {
            Log.error("could not re-couple the pointer to the mouse")
        }
        if let point { warp(to: point) }
    }

    // MARK: - Pieces

    public static func warp(to point: ScreenPoint) {
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
    }

    /// Where the cursor actually is, as opposed to where it was last put.
    public static var location: ScreenPoint {
        guard let event = CGEvent(source: nil) else { return ScreenPoint(x: 0, y: 0) }
        return ScreenPoint(x: Double(event.location.x), y: Double(event.location.y))
    }

    /// The same question asked of AppKit, which answers from the window server rather than
    /// from this process's copy of the event stream.
    ///
    /// Worth having separately: while the pointer is on the other Mac every movement event is
    /// deleted, so `location` can sit frozen at the parked position while the cursor is
    /// visibly somewhere else. Measuring drift needs a reader that cannot be fooled that way.
    public static var liveLocation: ScreenPoint {
        let p = NSEvent.mouseLocation
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return ScreenPoint(x: Double(p.x), y: Double(height - p.y))
    }

    /// Puts the cursor back at `point` and re-uncouples it. Only used by the optional
    /// re-parking timer; the capture itself should make it unnecessary.
    public static func hold(at point: ScreenPoint) {
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    @discardableResult
    public static func reattachToHardware() -> Bool {
        CGAssociateMouseAndMouseCursorPosition(1) == .success
    }

    /// Removes the quarter-second deafness that normally follows a warp.
    ///
    /// Without this, parking the cursor would suppress the very hardware events we are trying
    /// to forward — the other Mac's pointer would stutter to a halt just after arriving.
    public static func allowEventsDuringWarps() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Log.warn("could not open the session event source; parking may suppress input")
            return
        }
        source.localEventsSuppressionInterval = 0
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
    }

    private static var crashSafetyInstalled = false

    /// Re-couples the pointer and un-hides the cursor if this process exits unexpectedly.
    public static func installCrashSafety() {
        guard !crashSafetyInstalled else { return }
        crashSafetyInstalled = true
        atexit {
            _ = LocalPointer.enableBackgroundCursorControl()
            CGDisplayShowCursor(CGMainDisplayID())
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return [CGMainDisplayID()]
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return [CGMainDisplayID()]
        }
        return Array(ids.prefix(Int(count)))
    }
}
