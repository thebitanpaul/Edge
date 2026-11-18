import Foundation

/// What Edge's Control Center controls show, and how they talk back to the app.
///
/// The controls live in a separate, sandboxed extension that cannot see the app's state, run
/// its code, or signal it. So the conversation is two one-way channels, both deliberately dull:
///
/// - **App → control:** the app writes this small file whenever what the control should show
///   changes, then asks WidgetKit to reload. The extension is allowed to read exactly this one
///   directory and nothing else.
/// - **Control → app:** the switch's intent opens an `edge-control://` link, which Launch
///   Services delivers to the running app — or starts the app first.
///
/// This module is shared by both sides so they cannot drift apart on the format.
public struct ControlState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case notSetUp      // no pairing yet
        case stopped
        case connecting    // primary, dialling
        case ready         // secondary, waiting to be dialled
        case connected
        case away          // primary, pointer is on the other Mac
    }

    public var phase: Phase
    public var peerName: String?

    public init(phase: Phase, peerName: String? = nil) {
        self.phase = phase
        self.peerName = peerName
    }

    /// Works out the phase from the facts the menu-bar app already has.
    public init(paired: Bool, running: Bool, connected: Bool, pointerAway: Bool,
                isPrimary: Bool, peerName: String?) {
        let phase: Phase
        if !paired { phase = .notSetUp }
        else if !running { phase = .stopped }
        else if connected { phase = isPrimary && pointerAway ? .away : .connected }
        else { phase = isPrimary ? .connecting : .ready }
        self.init(phase: phase, peerName: connected ? peerName : nil)
    }

    /// Lit up in Control Center: anything but stopped.
    public var isOn: Bool { phase != .stopped && phase != .notSetUp }

    /// The line under "Edge" on a medium-sized control.
    public var subtitle: String {
        switch phase {
        case .notSetUp:   return "Not set up"
        case .stopped:    return "Off"
        case .connecting: return "Connecting…"
        case .ready:      return "Ready"
        case .connected:  return peerName.map { "On · \($0)" } ?? "On"
        case .away:       return peerName.map { "Pointer on \($0)" } ?? "Pointer on the other Mac"
        }
    }

    /// The same cursor family as the menu-bar icon, so the two read as one app.
    public var symbol: String {
        switch phase {
        case .notSetUp, .stopped: return "cursorarrow.slash"
        case .connecting, .ready: return "cursorarrow"
        case .connected:          return "cursorarrow.rays"
        case .away:               return "arrow.right.to.line"
        }
    }

    // MARK: - Shared constants

    /// Start and quit rather than "toggle": a tap that starts the app from cold races with the
    /// secondary starting itself, and a toggle that arrived second would turn it straight back
    /// off. Saying which way to go makes a repeated or late tap harmless.
    public static let scheme = "edge-control"
    public static let startURL = URL(string: "edge-control://start")!
    public static let stopURL = URL(string: "edge-control://stop")!
    /// Opens Edge's whole menu where the pointer is — the Edge Options control.
    public static let optionsURL = URL(string: "edge-control://options")!

    public static let extensionBundleID = "app.edge.cli.controls"
    public static let powerKind = "app.edge.cli.controls.power"
    public static let optionsKind = "app.edge.cli.controls.options"

    // MARK: - The file

    /// Always under the real home directory, whatever `EDGE_HOME` says: the extension's
    /// sandbox lets it read this one place and no other, and inside the sandbox the usual
    /// home-directory APIs answer with the extension's own container instead.
    public static var fileURL: URL {
        let home: String
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Edge/control.json")
    }

    public static func read() -> ControlState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ControlState.self, from: data)
    }

    public func write() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
