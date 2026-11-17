import Foundation

/// What a running `connect` or `listen` publishes about itself, so another command — or you,
/// a week later — can ask what is going on without reading a log.
///
/// A file rather than a socket: the information is tiny, advisory, and most useful exactly
/// when something has gone wrong and a socket would be the thing that is broken.
public struct RuntimeState: Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case sharing     // this Mac's keyboard and mouse are being shared out
        case listening   // this Mac is lending its screen
    }

    public var role: Role
    public var pid: Int32
    public var startedAt: Date
    public var updatedAt: Date
    public var connected: Bool
    public var peerName: String?
    public var endpoint: String?
    /// Only meaningful for `.sharing`: whether the pointer is currently on the other Mac.
    public var pointerIsRemote: Bool?
    /// False when started with `--link-only`: connected, but not capturing anything.
    public var sharingInput: Bool = true
    public var lastError: String?
    /// Most recent round-trip time, so a status display can show it without its own link.
    public var rttMillis: Double?
    /// Whether clipboard sharing actually negotiated on, as opposed to being configured on.
    public var clipboardActive: Bool = false

    public init(role: Role, peerName: String? = nil) {
        self.role = role
        self.pid = ProcessInfo.processInfo.processIdentifier
        self.startedAt = Date()
        self.updatedAt = Date()
        self.connected = false
        self.peerName = peerName
        self.sharingInput = true
    }

    /// True when the process that wrote this is still alive. A stale file left behind by a
    /// crash should not be reported as a running session.
    public var isLive: Bool {
        guard pid > 0 else { return false }
        // Signal 0 performs the permission and existence checks without sending anything.
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public var uptime: TimeInterval { Date().timeIntervalSince(startedAt) }

    static func url(for role: Role) -> URL {
        Paths.supportDirectory.appendingPathComponent("state-\(role.rawValue).json")
    }

    public func save() {
        var copy = self
        copy.updatedAt = Date()
        guard let data = try? JSONEncoder.continuousJSON.encode(copy) else { return }
        try? Paths.ensureSupportDirectory()
        try? AtomicFile.write(data, to: Self.url(for: role), mode: 0o600)
    }

    public static func load(_ role: Role) -> RuntimeState? {
        guard let data = try? Data(contentsOf: url(for: role)) else { return nil }
        return try? JSONDecoder.continuousJSON.decode(RuntimeState.self, from: data)
    }

    public static func clear(_ role: Role) {
        try? FileManager.default.removeItem(at: url(for: role))
    }

    /// Another live session of the same kind on this Mac, if there is one.
    ///
    /// Two sessions means two event taps, two sets of forwarded events and two processes
    /// taking turns hiding and showing the cursor. The symptoms -- a laggy pointer on the
    /// other Mac, a cursor here that takes seconds to go away -- look like bugs in the
    /// session rather than like there being two of it, so it is worth refusing outright.
    public static func existing(_ role: Role) -> RuntimeState? {
        guard let state = load(role), state.isLive,
              state.pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return state
    }

    public static var all: [RuntimeState] {
        [Role.sharing, .listening].compactMap { load($0) }
    }
}
