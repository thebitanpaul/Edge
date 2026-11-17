import Foundation
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

/// Local pointer state on the sending Mac while the other one has the pointer.
public enum LocalPointer {
    /// Stops the physical device from moving this Mac's own pointer.
    ///
    /// Only needed when the tap had to fall back to the session level. With a HID-level tap
    /// the movement is deleted before the window server sees it, so the cursor never moves and
    /// this is unnecessary — which is just as well, because the setting is global and a
    /// process that died while it was off would be an unpleasant thing to debug.
    @discardableResult
    public static func detachFromHardware() -> Bool {
        let result = CGAssociateMouseAndMouseCursorPosition(0)
        if result != .success { Log.warn("could not detach the pointer from the hardware (\(result.rawValue))") }
        return result == .success
    }

    @discardableResult
    public static func reattachToHardware() -> Bool {
        let result = CGAssociateMouseAndMouseCursorPosition(1)
        if result != .success { Log.error("could not re-attach the pointer to the hardware (\(result.rawValue))") }
        return result == .success
    }

    public static func warp(to point: ScreenPoint) {
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
    }

    /// Hides the cursor on every display.
    ///
    /// `CGDisplayHideCursor` is reference counted per process and historically only takes
    /// effect for the frontmost application, so a background tool may well be refused. That is
    /// survivable — a stationary cursor parked at the screen edge is a reasonable thing to
    /// leave behind — so the result is reported rather than treated as fatal.
    @discardableResult
    public static func hide() -> Bool {
        var hidAny = false
        for id in activeDisplayIDs() where CGDisplayHideCursor(id) == .success {
            hidAny = true
        }
        return hidAny
    }

    @discardableResult
    public static func show() -> Bool {
        var shown = false
        for id in activeDisplayIDs() where CGDisplayShowCursor(id) == .success {
            shown = true
        }
        return shown
    }

    private static var crashSafetyInstalled = false

    /// Re-couples the pointer and un-hides the cursor if this process exits unexpectedly.
    ///
    /// Detaching the pointer is a window-server setting, not a property of this process, so a
    /// crash at the wrong moment could in principle leave the Mac with a cursor that does not
    /// follow the mouse. `atexit` does not cover every way a process can die, but it covers
    /// the ones that are survivable at all.
    public static func installCrashSafety() {
        guard !crashSafetyInstalled else { return }
        crashSafetyInstalled = true
        atexit {
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
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
