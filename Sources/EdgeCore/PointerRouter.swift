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

    /// How far you must push against an edge before the pointer goes through it.
    ///
    /// Without this a single pixel of movement crosses, which is fine going out — the screen
    /// edge stops the cursor and you naturally keep pushing — but wrong coming back. The
    /// pointer arrives near the far screen's edge, so the first movement back the way you came
    /// would throw it home again. Requiring sustained pressure makes both directions feel the
    /// same: lean on the edge and you go through, graze it and you do not.
    public var edgePressureThreshold: Double = 24

    public private(set) var mode: Mode = .local
    /// Position in the combined coordinate space, meaningful only while remote.
    public private(set) var virtualPointer = ScreenPoint(x: 0, y: 0)
    /// Where this Mac's pointer was when it left, so it can be put back if nothing better
    /// is known.
    public private(set) var departurePoint = ScreenPoint(x: 0, y: 0)

    /// `nil` until the other Mac has reported its screens. Without it nothing is ever
    /// swallowed — the single most important invariant here.
    public var layout: ScreenLayout? {
        didSet { pressure = 0 }
    }

    /// Movement accumulated against the current edge. Reset the moment you stop pushing.
    private var pressure: Double = 0

    /// Exposed for diagnostics: how close the pointer is to going through.
    public var edgePressure: Double { pressure }

    /// Blocks handover without affecting anything else.
    ///
    /// Set while a mouse button is held: dragging a window towards the far edge should move
    /// the window, not throw the pointer onto the other Mac and leave the drag stranded
    /// half-way across the screen.
    public var allowCrossing: Bool = true {
        didSet { if !allowCrossing { pressure = 0 } }
    }

    /// How near the shared edge counts as heading for it; see `isApproachingEdge`.
    public var approachDistance: Double = 160

    public init(layout: ScreenLayout? = nil) {
        self.layout = layout
    }

    public var isRemote: Bool { mode == .remote }

    // MARK: - Movement

    public mutating func pointerMoved(localLocation: ScreenPoint, delta: ScreenPoint) -> Decision {
        guard let layout else { return .passThrough }

        let outward = layout.outwardComponent(of: delta)

        switch mode {
        case .local:
            // Pressure only builds while the pointer is actually against the edge and still
            // heading that way; anything else resets it.
            guard allowCrossing, layout.isAtTransferEdge(localLocation), outward > 0 else {
                pressure = 0
                return .passThrough
            }
            pressure += outward
            guard pressure >= edgePressureThreshold else { return .passThrough }

            pressure = 0
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

            if layout.isPastReturnEdge(virtual: moved), outward < 0 {
                pressure += -outward
                if pressure >= edgePressureThreshold {
                    pressure = 0
                    mode = .local
                    return .comeBack(local: layout.returnPoint(enteringLocalAt: moved))
                }
            } else {
                pressure = 0
            }

            let remote = layout.clampToRemote(virtual: moved)
            // Snap the tracked position back onto a real screen. Without this, holding the
            // pointer against the far edge builds up an invisible offset, and coming back
            // then needs that same distance travelled before anything happens.
            virtualPointer = layout.virtual(fromRemote: remote)
            return .forward(remote: remote)
        }
    }

    /// Whether the pointer, still here, is close to the shared edge and moving towards it.
    ///
    /// Used to wake the other Mac's Wi-Fi radio ahead of the crossing, so the first
    /// movements over there are not the ones that wait for it. Only a hint: nothing about
    /// where events go depends on it.
    public func isApproachingEdge(localLocation: ScreenPoint, delta: ScreenPoint) -> Bool {
        guard mode == .local, allowCrossing, let layout else { return false }
        return layout.outwardComponent(of: delta) > 0
            && layout.isAtTransferEdge(localLocation, tolerance: approachDistance)
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
        pressure = 0
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
