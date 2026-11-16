import Foundation
import CoreGraphics

/// This Mac's displays, in the same coordinate space `CGEvent` uses for pointer positions:
/// the main display's top-left corner is the origin and y grows downwards.
public enum Displays {
    public static func current() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            let b = CGDisplayBounds(id)
            return Display(x: Int32(b.origin.x.rounded()),
                           y: Int32(b.origin.y.rounded()),
                           width: Int32(b.width.rounded()),
                           height: Int32(b.height.rounded()),
                           isMain: id == main)
        }
    }

    /// Where the pointer is right now, in that same space.
    public static var pointerLocation: ScreenPoint {
        guard let event = CGEvent(source: nil) else { return ScreenPoint(x: 0, y: 0) }
        return ScreenPoint(x: Double(event.location.x), y: Double(event.location.y))
    }
}

/// Notices when a display is plugged in, unplugged, or rearranged.
///
/// This is not a nicety for the setup in mind: an external monitor that switches between two
/// Macs changes *both* machines' layouts the moment the input is switched. A layout worked out
/// once at connect time would be wrong within minutes.
public final class DisplayWatcher {
    public var onChange: (([Display]) -> Void)?

    private var registered = false
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "app.continuous.displays")

    public init() {}

    public func start() {
        guard !registered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard let userInfo else { return }
            // Reconfiguration is reported as a begin/end pair per display; acting on the
            // "begin" half reads a layout that is still mid-change.
            guard !flags.contains(.beginConfigurationFlag) else { return }
            Unmanaged<DisplayWatcher>.fromOpaque(userInfo).takeUnretainedValue().scheduleEmit()
        }, context)

        if status == .success {
            registered = true
        } else {
            Log.warn("could not register for display changes (\(status.rawValue)); layout will not follow a monitor being switched")
        }
    }

    public func stop() {
        guard registered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback({ _, _, _ in }, context)
        registered = false
        debounce?.cancel()
    }

    /// Several displays settle over a few hundred milliseconds; emit once they have.
    private func scheduleEmit() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let displays = Displays.current()
            Log.debug("display layout changed: \(displays.count) display(s)")
            self.onChange?(displays)
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    deinit { stop() }
}
