import Foundation

// MARK: - Geometry

public struct ScreenPoint: Equatable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var description: String { String(format: "(%.0f, %.0f)", x, y) }
}

public struct ScreenRect: Equatable, Sendable, CustomStringConvertible {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(_ p: ScreenPoint) -> Bool {
        p.x >= x && p.x < maxX && p.y >= y && p.y < maxY
    }

    /// Closest point inside this rectangle, staying a hair inside the far edges so the result
    /// is a position the pointer can actually occupy.
    public func clamp(_ p: ScreenPoint) -> ScreenPoint {
        ScreenPoint(x: min(max(p.x, x), maxX - 1),
                    y: min(max(p.y, y), maxY - 1))
    }

    public func squaredDistance(to p: ScreenPoint) -> Double {
        let c = clamp(p)
        let dx = c.x - p.x, dy = c.y - p.y
        return dx * dx + dy * dy
    }

    public static func union(_ rects: [ScreenRect]) -> ScreenRect? {
        guard let first = rects.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.maxX, maxY = first.maxY
        for r in rects.dropFirst() {
            minX = min(minX, r.x); minY = min(minY, r.y)
            maxX = max(maxX, r.maxX); maxY = max(maxY, r.maxY)
        }
        return ScreenRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public var description: String {
        String(format: "%.0f×%.0f at (%.0f, %.0f)", width, height, x, y)
    }
}

public extension Display {
    var rect: ScreenRect {
        ScreenRect(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
    }
}

// MARK: - Arrangement

public enum ScreenEdge: String, Codable, CaseIterable, Sendable {
    case left, right, top, bottom

    public var isHorizontal: Bool { self == .left || self == .right }

    public var opposite: ScreenEdge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    public static func parse(_ s: String) -> ScreenEdge? { ScreenEdge(rawValue: s.lowercased()) }
}

/// How the two Macs line up along the shared edge when their screens are different sizes.
public enum ScreenAlignment: String, Codable, CaseIterable, Sendable {
    /// Stretch the remote span to match the local one, so the pointer leaves at the same
    /// fraction of the way down and never meets a dead end. The default: with a laptop screen
    /// next to a much taller external monitor, the fixed alignments leave regions you can
    /// point at on one Mac but cannot reach on the other.
    case proportional
    /// Top edges flush (horizontal arrangement) or left edges flush (vertical).
    case start
    case center
    /// Bottom edges flush (horizontal) or right edges flush (vertical).
    case end

    public static func parse(_ s: String) -> ScreenAlignment? {
        switch s.lowercased() {
        case "proportional", "stretch", "fit": return .proportional
        case "start", "top", "left": return .start
        case "center", "centre", "middle": return .center
        case "end", "bottom", "right": return .end
        default: return nil
        }
    }
}

// MARK: - The combined desktop

/// One coordinate space covering both Macs' screens.
///
/// The host keeps a single virtual pointer position in this space. Its own screens occupy their
/// real CoreGraphics coordinates; the other Mac's screens are placed next to them along the
/// configured edge, and mapped back to that Mac's own coordinates on the way out.
///
/// Both sides are *unions of displays*, not single screens, which is what makes an external
/// monitor work. A monitor plugged into the left Mac simply widens the left Mac's union; the
/// same monitor switched over to the right Mac widens the right one instead. The handover
/// point moves on its own, and neither side needs to know the monitor exists.
public struct ScreenLayout: Sendable {
    public let localDisplays: [ScreenRect]
    public let remoteDisplays: [ScreenRect]
    public let localBounds: ScreenRect
    /// The remote Mac's bounds in *its own* coordinate space.
    public let remoteBounds: ScreenRect
    public let edge: ScreenEdge
    public let alignment: ScreenAlignment

    // Affine map from the remote Mac's coordinates into the virtual space.
    private let scaleX: Double
    private let scaleY: Double
    private let offsetX: Double
    private let offsetY: Double

    public init?(localDisplays: [Display], remoteDisplays: [Display],
                 edge: ScreenEdge, alignment: ScreenAlignment) {
        let local = localDisplays.map(\.rect)
        let remote = remoteDisplays.map(\.rect)
        guard let localBounds = ScreenRect.union(local),
              let remoteBounds = ScreenRect.union(remote),
              localBounds.width > 0, localBounds.height > 0,
              remoteBounds.width > 0, remoteBounds.height > 0
        else { return nil }

        self.localDisplays = local
        self.remoteDisplays = remote
        self.localBounds = localBounds
        self.remoteBounds = remoteBounds
        self.edge = edge
        self.alignment = alignment

        // The cross axis is the one running along the shared edge.
        let localSpan = edge.isHorizontal ? localBounds.height : localBounds.width
        let remoteSpan = edge.isHorizontal ? remoteBounds.height : remoteBounds.width
        let scale = alignment == .proportional ? localSpan / remoteSpan : 1

        let scaledRemoteSpan = remoteSpan * scale
        let localStart = edge.isHorizontal ? localBounds.y : localBounds.x
        let localMid = edge.isHorizontal ? localBounds.midY : localBounds.midX
        let localEnd = edge.isHorizontal ? localBounds.maxY : localBounds.maxX

        let crossStart: Double
        switch alignment {
        case .proportional, .start: crossStart = localStart
        case .center:               crossStart = localMid - scaledRemoteSpan / 2
        case .end:                  crossStart = localEnd - scaledRemoteSpan
        }

        if edge.isHorizontal {
            scaleX = 1
            scaleY = scale
            offsetX = edge == .right
                ? localBounds.maxX - remoteBounds.x          // remote's left edge meets ours
                : localBounds.x - remoteBounds.maxX          // remote's right edge meets ours
            offsetY = crossStart - remoteBounds.y * scale
        } else {
            scaleX = scale
            scaleY = 1
            offsetY = edge == .bottom
                ? localBounds.maxY - remoteBounds.y
                : localBounds.y - remoteBounds.maxY
            offsetX = crossStart - remoteBounds.x * scale
        }
    }

    // MARK: coordinate mapping

    public func virtual(fromRemote p: ScreenPoint) -> ScreenPoint {
        ScreenPoint(x: p.x * scaleX + offsetX, y: p.y * scaleY + offsetY)
    }

    public func remote(fromVirtual p: ScreenPoint) -> ScreenPoint {
        ScreenPoint(x: (p.x - offsetX) / scaleX, y: (p.y - offsetY) / scaleY)
    }

    /// Where the other Mac's screens sit in the virtual space.
    public var remoteBoundsInVirtual: ScreenRect {
        let origin = virtual(fromRemote: ScreenPoint(x: remoteBounds.x, y: remoteBounds.y))
        return ScreenRect(x: origin.x, y: origin.y,
                          width: remoteBounds.width * scaleX,
                          height: remoteBounds.height * scaleY)
    }

    public var remoteDisplaysInVirtual: [ScreenRect] {
        remoteDisplays.map { r in
            let origin = virtual(fromRemote: ScreenPoint(x: r.x, y: r.y))
            return ScreenRect(x: origin.x, y: origin.y,
                              width: r.width * scaleX, height: r.height * scaleY)
        }
    }

    // MARK: clamping

    /// Nearest point that actually lies on a screen.
    ///
    /// The union of several displays is rarely a rectangle — a laptop beside a taller monitor
    /// leaves corners that are inside the bounding box but on no screen at all. Snapping to the
    /// nearest real display is what stops the pointer disappearing into one of them.
    public static func nearestPoint(in rects: [ScreenRect], to p: ScreenPoint) -> ScreenPoint {
        if rects.contains(where: { $0.contains(p) }) { return p }
        var best: ScreenPoint?
        var bestDistance = Double.greatestFiniteMagnitude
        for r in rects {
            let d = r.squaredDistance(to: p)
            if d < bestDistance { bestDistance = d; best = r.clamp(p) }
        }
        return best ?? p
    }

    public func clampToLocal(_ p: ScreenPoint) -> ScreenPoint {
        Self.nearestPoint(in: localDisplays, to: p)
    }

    /// Clamps a virtual point onto the remote Mac's real screens and returns it in that Mac's
    /// own coordinates — ready to put straight into a pointer event over there.
    public func clampToRemote(virtual p: ScreenPoint) -> ScreenPoint {
        let inVirtual = Self.nearestPoint(in: remoteDisplaysInVirtual, to: p)
        return remote(fromVirtual: inVirtual)
    }

    // MARK: transitions

    /// Has the pointer reached the edge that leads to the other Mac, and is it still pushing?
    public func isLeavingLocal(at p: ScreenPoint, delta: ScreenPoint, tolerance: Double = 1) -> Bool {
        switch edge {
        case .right:  return p.x >= localBounds.maxX - tolerance && delta.x > 0
        case .left:   return p.x <= localBounds.x + tolerance && delta.x < 0
        case .bottom: return p.y >= localBounds.maxY - tolerance && delta.y > 0
        case .top:    return p.y <= localBounds.y + tolerance && delta.y < 0
        }
    }

    /// Where the pointer should appear on the other Mac, in that Mac's own coordinates.
    public func entryPoint(leavingLocalAt p: ScreenPoint, inset: Double = 2) -> ScreenPoint {
        let remoteVirtual = remoteBoundsInVirtual
        var entry = p
        switch edge {
        case .right:  entry.x = remoteVirtual.x + inset
        case .left:   entry.x = remoteVirtual.maxX - inset
        case .bottom: entry.y = remoteVirtual.y + inset
        case .top:    entry.y = remoteVirtual.maxY - inset
        }
        return clampToRemote(virtual: entry)
    }

    /// Has the pointer come back past the shared edge into our own screens?
    public func isReturningToLocal(virtual p: ScreenPoint, delta: ScreenPoint) -> Bool {
        switch edge {
        case .right:  return p.x < localBounds.maxX && delta.x < 0
        case .left:   return p.x >= localBounds.x && delta.x > 0
        case .bottom: return p.y < localBounds.maxY && delta.y < 0
        case .top:    return p.y >= localBounds.y && delta.y > 0
        }
    }

    /// Where the pointer should reappear on this Mac, in this Mac's own coordinates.
    public func returnPoint(enteringLocalAt p: ScreenPoint, inset: Double = 2) -> ScreenPoint {
        var entry = p
        switch edge {
        case .right:  entry.x = localBounds.maxX - inset
        case .left:   entry.x = localBounds.x + inset
        case .bottom: entry.y = localBounds.maxY - inset
        case .top:    entry.y = localBounds.y + inset
        }
        return clampToLocal(entry)
    }
}

// MARK: - Drawing it

public extension ScreenLayout {
    /// An ASCII plan of the combined desktop.
    ///
    /// Worth the few lines it costs: "is the arrangement right?" is otherwise answered only by
    /// pushing the pointer at a screen edge and seeing whether anything happens.
    func diagram(width columns: Int = 72, localName: String, remoteName: String) -> String {
        let all = localDisplays + remoteDisplaysInVirtual
        guard let bounds = ScreenRect.union(all), bounds.width > 0, bounds.height > 0 else {
            return "(no displays)"
        }

        // Characters are about twice as tall as they are wide.
        let rows = max(6, Int((Double(columns) * (bounds.height / bounds.width) / 2.1).rounded()))
        var grid = [[Character]](repeating: [Character](repeating: " ", count: columns), count: rows)

        func plot(_ r: ScreenRect, fill: Character, border: Character) {
            let x0 = Int(((r.x - bounds.x) / bounds.width * Double(columns)).rounded())
            let x1 = Int(((r.maxX - bounds.x) / bounds.width * Double(columns)).rounded()) - 1
            let y0 = Int(((r.y - bounds.y) / bounds.height * Double(rows)).rounded())
            let y1 = Int(((r.maxY - bounds.y) / bounds.height * Double(rows)).rounded()) - 1
            guard x1 >= x0, y1 >= y0 else { return }
            for yy in max(0, y0)...min(rows - 1, y1) {
                for xx in max(0, x0)...min(columns - 1, x1) {
                    let onBorder = yy == y0 || yy == y1 || xx == x0 || xx == x1
                    grid[yy][xx] = onBorder ? border : fill
                }
            }
        }

        for r in localDisplays { plot(r, fill: " ", border: "#") }
        for r in remoteDisplaysInVirtual { plot(r, fill: " ", border: "+") }

        /// Writes a caption inside a screen, keeping clear of its borders and shortening it
        /// if the screen is too narrow — a name that spills over the edge makes two adjacent
        /// screens look like one.
        func label(_ text: String, in r: ScreenRect) {
            let x0 = Int(((r.x - bounds.x) / bounds.width * Double(columns)).rounded())
            let x1 = Int(((r.maxX - bounds.x) / bounds.width * Double(columns)).rounded()) - 1
            let y0 = Int(((r.y - bounds.y) / bounds.height * Double(rows)).rounded())
            let y1 = Int(((r.maxY - bounds.y) / bounds.height * Double(rows)).rounded()) - 1
            let inner = x1 - x0 - 1
            guard inner >= 3, y1 - y0 >= 2 else { return }

            let row = min(max((y0 + y1) / 2, y0 + 1), y1 - 1)
            guard row >= 0, row < rows else { return }

            var caption = text
            if caption.count > inner { caption = String(caption.prefix(inner - 1)) + "…" }
            let start = x0 + 1 + max(0, (inner - caption.count) / 2)
            guard start > 0, start + caption.count <= columns else { return }
            for (i, ch) in caption.enumerated() { grid[row][start + i] = ch }
        }

        for (i, r) in localDisplays.enumerated() {
            label(localDisplays.count == 1 ? localName : "\(localName) \(i + 1)", in: r)
        }
        for (i, r) in remoteDisplaysInVirtual.enumerated() {
            label(remoteDisplays.count == 1 ? remoteName : "\(remoteName) \(i + 1)", in: r)
        }

        return grid.map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
                   .joined(separator: "\n")
    }
}
