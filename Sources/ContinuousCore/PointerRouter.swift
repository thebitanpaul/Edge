import Foundation

/// Decides where the pointer is and what should happen to each movement.
///
/// Deliberately a plain value type with no CoreGraphics, no sockets and no clock. The event
/// tap that uses it can swallow this Mac's keyboard and pointer, so the rules about *when*
/// that happens need to be checkable without a live link, two Macs and a willingness to get
/// locked out if a case was missed.
public struct PointerRouter: Sendable {
    public enum Mode: Sendable, Equatable { case local, remote }

    public enum Decision: Sendable, Equatable {
        /// Leave the event alone; this Mac handles it as usual.
        case passThrough
        /// The pointer has just left. Send it to the other Mac at `entry`, in that Mac's
        /// coordinates, and start swallowing events.
        case cross(entry: ScreenPoint)
        /// The pointer is on the other Mac. Send it to `remote` and keep swallowing.
        case forward(remote: ScreenPoint)
        /// The pointer has come back. Put this Mac's own pointer at `local` and stop
        /// swallowing.
        case comeBack(local: ScreenPoint)
    }

    public private(set) var mode: Mode = .local
    /// Position in the combined coordinate space, meaningful only while remote.
    public private(set) var virtualPointer = ScreenPoint(x: 0, y: 0)
    /// Where this Mac's pointer was when it left, so it can be put back if nothing better
    /// is known.
    public private(set) var departurePoint = ScreenPoint(x: 0, y: 0)

    /// `nil` until the other Mac has reported its screens. Without it nothing is ever
    /// swallowed — the single most important invariant here.
    public var layout: ScreenLayout?

    public init(layout: ScreenLayout? = nil) {
        self.layout = layout
    }

    public var isRemote: Bool { mode == .remote }

    // MARK: - Movement

    public mutating func pointerMoved(localLocation: ScreenPoint, delta: ScreenPoint) -> Decision {
        guard let layout else { return .passThrough }

        switch mode {
        case .local:
            guard layout.isLeavingLocal(at: localLocation, delta: delta) else { return .passThrough }
            let entry = layout.entryPoint(leavingLocalAt: localLocation)
            mode = .remote
            departurePoint = localLocation
            virtualPointer = layout.virtual(fromRemote: entry)
            return .cross(entry: entry)

        case .remote:
            // While remote the hardware is detached from this Mac's pointer, so absolute
            // positions are meaningless and only the deltas carry information.
            var moved = virtualPointer
            moved.x += delta.x
            moved.y += delta.y

            if layout.isReturningToLocal(virtual: moved, delta: delta) {
                mode = .local
                return .comeBack(local: layout.returnPoint(enteringLocalAt: moved))
            }

            let remote = layout.clampToRemote(virtual: moved)
            // Snap the tracked position back onto a real screen. Without this, holding the
            // pointer against the far edge builds up an invisible offset, and coming back
            // then needs that same distance travelled before anything happens.
            virtualPointer = layout.virtual(fromRemote: remote)
            return .forward(remote: remote)
        }
    }

    /// Where the pointer currently is on the other Mac, for events that carry a position but
    /// no movement — a click, say.
    public func currentRemotePoint() -> ScreenPoint? {
        guard mode == .remote, let layout else { return nil }
        return layout.clampToRemote(virtual: virtualPointer)
    }

    // MARK: - Forced return

    /// Takes the pointer back regardless of where it was heading: the escape chord, a dropped
    /// link, a silent peer, a disabled tap. Returns where this Mac's pointer should be put,
    /// or `nil` if it was never away.
    @discardableResult
    public mutating func forceLocal() -> ScreenPoint? {
        guard mode == .remote else { return nil }
        mode = .local
        let destination = layout?.returnPoint(enteringLocalAt: virtualPointer) ?? departurePoint
        return destination
    }

    /// Replaces the arrangement, as happens when a monitor is switched between the two Macs.
    ///
    /// Always returns the pointer here first: the position being tracked refers to screens
    /// that may have just stopped existing.
    public mutating func replaceLayout(_ newLayout: ScreenLayout?) -> ScreenPoint? {
        let destination = forceLocal()
        layout = newLayout
        return destination
    }
}
