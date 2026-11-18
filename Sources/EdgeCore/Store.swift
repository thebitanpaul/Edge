import Foundation

public enum EdgeError: LocalizedError {
    case insecurePermissions(path: String, mode: String)
    case noSuchPairing(String)
    case notPaired
    case ambiguous(String, [String])
    case badPairingCode(String)
    case invalidArgument(String)
    case handshakeFailed(String)
    case timedOut(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .insecurePermissions(let p, let m):
            return "\(p) has mode \(m) but must be 0600.\n  Fix it with:  chmod 600 \"\(p)\""
        case .noSuchPairing(let s):
            return "no pairing matches '\(s)' — run `edge pair list` to see what exists"
        case .notPaired:
            return "no pairings yet.\n  On both Macs:  edge pair nearby   (or Set up in the menu bar)"
        case .ambiguous(let s, let options):
            return "'\(s)' matches more than one pairing: \(options.joined(separator: ", "))"
        case .badPairingCode(let s):
            return "that pairing code is not valid: \(s)"
        case .invalidArgument(let s):
            return s
        case .handshakeFailed(let s):
            return "handshake failed: \(s)"
        case .timedOut(let s):
            return "timed out: \(s)"
        case .transport(let s):
            return s
        }
    }
}

/// One shared secret between this Mac and exactly one other Mac.
///
/// The pairing exists from the moment a code is generated or typed in. The *identity* of the
/// Mac on the other end is learned at the first successful handshake and pinned from then on,
/// so a code that leaks after it has been used is no longer enough to impersonate the peer.
public struct Pairing: Codable, Sendable {
    public var psk: Data
    public var label: String
    public var createdAt: Date
    public var peerDeviceID: DeviceID?
    public var peerName: String?
    /// The peer's mDNS hostname, learned during the handshake. On networks where Bonjour
    /// browsing is blocked — most corporate ones — this is how the Mac is found again.
    public var peerHostName: String?
    /// An address you set by hand, for networks where discovery does not work.
    public var manualEndpoint: String?
    public var lastEndpoint: String?
    public var lastSeenAt: Date?
    /// The other Mac's screen arrangement as of the last connection, so `edge layout`
    /// can show the combined desktop without needing a live link.
    public var peerDisplays: [Display]?

    public init(psk: Data, label: String, createdAt: Date = Date()) {
        self.psk = psk
        self.label = label
        self.createdAt = createdAt
    }

    public var keyID: Data { Crypto.deriveKeyID(fromPSK: psk) }

    /// True for a name this app invented rather than one a person chose.
    ///
    /// Both Macs name a new pairing locally and identically, so two machines each show
    /// "Mac 1" and neither tells you anything about the other. Once a handshake reveals who
    /// is actually on the far end, a name nobody chose should give way to the real one.
    public var hasGeneratedLabel: Bool {
        label.range(of: "^Mac [0-9]+$", options: .regularExpression) != nil
            || label.hasPrefix("pairing-")
    }
    public var keyIDHex: String { Crypto.hex(keyID) }
    public var isBound: Bool { peerDeviceID != nil }

    public var statusText: String {
        if let id = peerDeviceID {
            let name = peerName.map { " (\($0))" } ?? ""
            return "bound to \(id.short)\(name)"
        }
        return "waiting for first connection"
    }
}

public struct SecretStore: Codable, Sendable {
    public var version: Int = 1
    public var pairings: [Pairing] = []

    public init() {}

    /// Resolves a user-typed needle against label, key id prefix, or bound device id prefix.
    public func index(matching needle: String) throws -> Int {
        let n = needle.lowercased().replacingOccurrences(of: "-", with: "")
        var hits: [Int] = []
        for (i, p) in pairings.enumerated() {
            if p.label.lowercased() == needle.lowercased() { return i }
            if p.keyIDHex.hasPrefix(n) && !n.isEmpty { hits.append(i); continue }
            if let id = p.peerDeviceID, id.compact.lowercased().hasPrefix(n), !n.isEmpty {
                hits.append(i); continue
            }
            if p.label.lowercased().contains(needle.lowercased()) { hits.append(i) }
        }
        let unique = Array(Set(hits)).sorted()
        if unique.isEmpty { throw EdgeError.noSuchPairing(needle) }
        if unique.count > 1 {
            throw EdgeError.ambiguous(needle, unique.map { pairings[$0].label })
        }
        return unique[0]
    }

    // MARK: persistence

    /// Identifies the *set of keys* currently on disk, and nothing else about the file.
    ///
    /// A modification date would be wrong here, and wrong in a way that is hard to see: a
    /// successful connection writes to this file — it records which Mac the pairing bound to
    /// and when it was last seen — so every connection looks like a re-pairing. A listener
    /// watching the date tore itself down a moment after every link came up.
    public static var keySetFingerprint: String {
        guard let store = try? load() else { return "none" }
        return store.pairings
            .map(\.keyIDHex)
            .sorted()
            .joined(separator: ",")
    }

    public static func load() throws -> SecretStore {
        let url = Paths.secretsFile
        guard FileManager.default.fileExists(atPath: url.path) else { return SecretStore() }
        try assertSecurePermissions(url)
        return try JSONDecoder.edgeJSON.decode(SecretStore.self, from: try Data(contentsOf: url))
    }

    public func save() throws {
        try Paths.ensureSupportDirectory()
        try AtomicFile.write(try JSONEncoder.edgeJSON.encode(self), to: Paths.secretsFile, mode: 0o600)
    }

    /// Refuse to read key material out of a group- or world-accessible file, as OpenSSH does.
    static func assertSecurePermissions(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let num = attrs[.posixPermissions] as? NSNumber else { return }
        let mode = num.int16Value & 0o777
        if mode & 0o077 != 0 {
            throw EdgeError.insecurePermissions(path: url.path,
                                                      mode: String(format: "%04o", mode))
        }
    }
}

/// Thread-safe view of the pairings, shared with the networking layer.
///
/// The networking callbacks run on their own queues, so key lookup, allowlist checks and the
/// first-connection binding all have to be serialized. Everything persists immediately — a
/// binding that is not on disk would be re-learned on the next run, which is exactly what
/// pinning is supposed to prevent.
public class PairingDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var store: SecretStore
    /// When true nothing is written to disk. Used by `selftest`, which must not disturb
    /// the real pairings on this Mac.
    private let inMemory: Bool
    /// Set when a connection binds a previously-unbound pairing, for the CLI to report.
    public var onBind: ((Pairing) -> Void)?
    /// Allows a bound pairing to accept a different device id (used by `--rebind`).
    public var allowRebind: Bool = false

    public init(store: SecretStore, inMemory: Bool = false) {
        self.store = store
        self.inMemory = inMemory
    }

    private func persist(_ store: SecretStore) throws {
        guard !inMemory else { return }
        try store.save()
    }

    public static func load() throws -> PairingDirectory {
        PairingDirectory(store: try SecretStore.load())
    }

    public var snapshot: SecretStore { lock.lock(); defer { lock.unlock() }; return store }

    public var allKeys: [PSKEntry] {
        lock.lock(); defer { lock.unlock() }
        return store.pairings.map { PSKEntry(psk: $0.psk) }
    }

    public func psk(forKeyID keyID: Data) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return store.pairings.first { Crypto.constantTimeEquals($0.keyID, keyID) }?.psk
    }

    /// Allowlist check, run after the peer has proven it holds the key.
    public func authorize(deviceID: DeviceID, keyID: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let idx = store.pairings.firstIndex(where: { Crypto.constantTimeEquals($0.keyID, keyID) })
        else { return false }
        if let bound = store.pairings[idx].peerDeviceID {
            return bound == deviceID || allowRebind
        }
        return true
    }

    /// Records who the peer turned out to be, pinning the pairing on first use.
    public func note(peer: PeerInfo) {
        lock.lock()
        var bound: Pairing?
        if let idx = store.pairings.firstIndex(where: { Crypto.constantTimeEquals($0.keyID, peer.keyID) }) {
            let wasUnbound = store.pairings[idx].peerDeviceID == nil
            store.pairings[idx].peerDeviceID = peer.deviceID
            store.pairings[idx].peerName = peer.name
            if !peer.hostName.isEmpty { store.pairings[idx].peerHostName = peer.hostName }
            if store.pairings[idx].hasGeneratedLabel, !peer.name.isEmpty {
                let taken = Set(store.pairings.enumerated()
                    .filter { $0.offset != idx }.map { $0.element.label })
                if !taken.contains(peer.name) { store.pairings[idx].label = peer.name }
            }
            store.pairings[idx].lastEndpoint = peer.endpoint
            store.pairings[idx].lastSeenAt = Date()
            if wasUnbound { bound = store.pairings[idx] }
            try? persist(store)
        }
        lock.unlock()
        if let bound { onBind?(bound) }
    }

    /// Caches the other Mac's screen arrangement against its pairing.
    public func noteDisplays(_ displays: [Display], forKeyID keyID: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = store.pairings.firstIndex(where: { Crypto.constantTimeEquals($0.keyID, keyID) })
        else { return }
        guard store.pairings[idx].peerDisplays != displays else { return }
        store.pairings[idx].peerDisplays = displays
        try? persist(store)
    }

    public func mutate(_ body: (inout SecretStore) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try body(&store)
        try persist(store)
    }
}

// MARK: - Config

public struct Config: Codable, Sendable {
    public var version: Int = 1
    /// TCP port the listening Mac binds. 0 asks the kernel for one and announces it over Bonjour.
    public var port: UInt16 = 52777
    /// Refuse peers that are neither on a private address nor on a subnet this Mac is
    /// attached to. See `NetworkAddress.isAcceptablePeer`.
    public var requireLocalNetwork: Bool = true
    /// Advertise over Bonjour so the other Mac can be found without typing an IP address.
    public var bonjourEnabled: Bool = true
    /// Which side of this Mac's screens the other Mac sits on, physically.
    public var remoteEdge: String = "right"
    /// How the two Macs line up along that edge when the screens are different sizes.
    public var remoteAlignment: String = "proportional"
    /// How far you must push against a screen edge, in points, before the pointer goes
    /// through it. Lower feels quicker; too low and the pointer bounces between the Macs.
    public var edgePressure: Double = 24
    /// Re-park this Mac's cursor on a timer while the pointer is on the other Mac.
    ///
    /// Off by default. Uncoupling the pointer from the mouse already stops the cursor
    /// moving, and once it is genuinely hidden a stray pixel or two cannot be seen anyway.
    /// Kept as an escape hatch; the session measures drift either way and will say so.
    public var holdLocalPointer: Bool = false
    /// Copy on one Mac, paste on the other.
    ///
    /// Off by default, and that is a deliberate default rather than caution for its own sake:
    /// whatever you last copied is quite often a password, and this sends it to the other
    /// machine every time it changes.
    public var clipboardSharing: Bool = false
    /// Carry images as well as text. Off by default — a screenshot is megabytes.
    public var clipboardImages: Bool = false
    /// Largest clipboard to carry, in bytes. Anything larger is left where it is.
    public var clipboardLimit: Int = 1 << 20
    /// Which physical link to use: `auto`, `cable` or `wifi`.
    ///
    /// A USB-C or Thunderbolt cable between two Macs appears as an ordinary wired interface,
    /// so with both a cable and Wi-Fi connected the system is free to pick either — and it
    /// will usually pick the one with a default route, which is Wi-Fi. Saying `cable` pins it
    /// to the link that is an order of magnitude quicker and not shared with anything else.
    public var preferredLink: String = "auto"
    /// Carry files dragged across the shared edge.
    ///
    /// On by default: unlike the clipboard, nothing crosses unless you deliberately drag it.
    public var fileSharing: Bool = true
    /// Show the files in Finder as they land, the way a completed download is shown.
    public var revealReceivedFiles: Bool = true
    public var logLevel: String = "info"

    public init() {}

    public var edge: ScreenEdge { ScreenEdge.parse(remoteEdge) ?? .right }

    public var link: LinkPreference { LinkPreference(rawValue: preferredLink) ?? .auto }

    /// What to tell the other Mac this one is willing to do.
    public var capabilities: Capabilities {
        var caps = Capabilities.baseline
        if clipboardSharing { caps.insert(.clipboard) }
        if fileSharing { caps.insert(.files) }
        return caps
    }
    public var alignment: ScreenAlignment { ScreenAlignment.parse(remoteAlignment) ?? .proportional }

    enum CodingKeys: String, CodingKey {
        case version, port, requireLocalNetwork, bonjourEnabled, logLevel
        case remoteEdge, remoteAlignment, edgePressure, holdLocalPointer
        case clipboardSharing, clipboardImages, clipboardLimit, preferredLink
        case fileSharing, revealReceivedFiles
        case requirePrivateNetwork   // the name this setting had before 0.1.0
    }

    /// Decoded field by field with defaults, so adding or renaming a setting never makes an
    /// existing config.json unreadable — the alternative is silently reverting every other
    /// setting the user chose.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 52777
        requireLocalNetwork = try c.decodeIfPresent(Bool.self, forKey: .requireLocalNetwork)
            ?? c.decodeIfPresent(Bool.self, forKey: .requirePrivateNetwork)
            ?? true
        bonjourEnabled = try c.decodeIfPresent(Bool.self, forKey: .bonjourEnabled) ?? true
        remoteEdge = try c.decodeIfPresent(String.self, forKey: .remoteEdge) ?? "right"
        remoteAlignment = try c.decodeIfPresent(String.self, forKey: .remoteAlignment) ?? "proportional"
        edgePressure = max(1, try c.decodeIfPresent(Double.self, forKey: .edgePressure) ?? 24)
        holdLocalPointer = try c.decodeIfPresent(Bool.self, forKey: .holdLocalPointer) ?? false
        clipboardSharing = try c.decodeIfPresent(Bool.self, forKey: .clipboardSharing) ?? false
        clipboardImages = try c.decodeIfPresent(Bool.self, forKey: .clipboardImages) ?? false
        clipboardLimit = max(1024, try c.decodeIfPresent(Int.self, forKey: .clipboardLimit) ?? (1 << 20))
        preferredLink = try c.decodeIfPresent(String.self, forKey: .preferredLink) ?? "auto"
        fileSharing = try c.decodeIfPresent(Bool.self, forKey: .fileSharing) ?? true
        revealReceivedFiles = try c.decodeIfPresent(Bool.self, forKey: .revealReceivedFiles) ?? true
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? "info"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(port, forKey: .port)
        try c.encode(requireLocalNetwork, forKey: .requireLocalNetwork)
        try c.encode(bonjourEnabled, forKey: .bonjourEnabled)
        try c.encode(remoteEdge, forKey: .remoteEdge)
        try c.encode(remoteAlignment, forKey: .remoteAlignment)
        try c.encode(edgePressure, forKey: .edgePressure)
        try c.encode(holdLocalPointer, forKey: .holdLocalPointer)
        try c.encode(clipboardSharing, forKey: .clipboardSharing)
        try c.encode(clipboardImages, forKey: .clipboardImages)
        try c.encode(clipboardLimit, forKey: .clipboardLimit)
        try c.encode(preferredLink, forKey: .preferredLink)
        try c.encode(fileSharing, forKey: .fileSharing)
        try c.encode(revealReceivedFiles, forKey: .revealReceivedFiles)
        try c.encode(logLevel, forKey: .logLevel)
    }

    public static func load() throws -> Config {
        guard let data = try? Data(contentsOf: Paths.configFile) else { return Config() }
        do {
            return try JSONDecoder.edgeJSON.decode(Config.self, from: data)
        } catch {
            Log.warn("config.json could not be read (\(error)); falling back to defaults")
            return Config()
        }
    }

    public func save() throws {
        try Paths.ensureSupportDirectory()
        try AtomicFile.write(try JSONEncoder.edgeJSON.encode(self), to: Paths.configFile, mode: 0o600)
    }
}
