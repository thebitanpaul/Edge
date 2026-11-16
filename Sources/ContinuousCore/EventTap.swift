import Foundation
import CoreGraphics

/// A `CGEventTap` on the Mac whose keyboard and mouse are being shared.
///
/// The tap is inserted at the head of the session tap chain in *active* mode, which means the
/// handler may return `nil` to swallow an event entirely. That is the whole trick: while the
/// pointer is on the other Mac, every key and every movement is consumed here and forwarded,
/// so this Mac sees nothing and the other one behaves as though the keyboard were plugged
/// into it.
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

        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask ?? Self.defaultMask,
                                           callback: callback,
                                           userInfo: refcon) else {
            // tapCreate returns nil for a missing permission as well as for bad arguments;
            // the permission is overwhelmingly the likely cause.
            throw Permissions.inputMonitoring().isGranted && Permissions.accessibility().isGranted
                ? StartFailure.couldNotCreate
                : StartFailure.notPermitted
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        self.port = port
        self.runLoopSource = source
        Log.debug("event tap installed")
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
    /// Stops the physical device from moving this Mac's own pointer. Movement still reaches
    /// the event tap as deltas, which is exactly what we want: the hardware drives the other
    /// Mac while this Mac's pointer stays put.
    public static func detachFromHardware() {
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    public static func reattachToHardware() {
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public static func warp(to point: ScreenPoint) {
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
    }

    @discardableResult
    public static func hide() -> Bool {
        CGDisplayHideCursor(CGMainDisplayID()) == .success
    }

    @discardableResult
    public static func show() -> Bool {
        CGDisplayShowCursor(CGMainDisplayID()) == .success
    }
}
