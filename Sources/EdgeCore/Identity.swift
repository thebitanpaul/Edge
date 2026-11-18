import Foundation
import SystemConfiguration

public enum Role: UInt8, Codable, Sendable, CustomStringConvertible {
    case host = 1       // owns the physical keyboard and mouse
    case client = 2     // lends its screen

    public var description: String { self == .host ? "host" : "client" }

    public static func parse(_ s: String) -> Role? {
        switch s.lowercased() {
        case "host", "server", "sender": return .host
        case "client", "receiver": return .client
        default: return nil
        }
    }
}

/// A stable 16-byte identifier for this Mac, generated once and persisted.
/// Used to key the peer allowlist and to bind handshake proofs to a specific machine.
public struct DeviceID: Hashable, Sendable, CustomStringConvertible, Codable {
    public let bytes: Data   // exactly 16

    public init?(bytes: Data) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    public init() {
        var uuid = UUID().uuid
        self.bytes = withUnsafeBytes(of: &uuid) { Data($0) }
    }

    public init?(string: String) {
        guard let d = CrockfordBase32.decode(string), d.count == 16 else { return nil }
        self.bytes = d
    }

    /// 26 Crockford characters, grouped for readability.
    public var description: String {
        let raw = CrockfordBase32.encode(bytes)
        return stride(from: 0, to: raw.count, by: 6).map { i -> String in
            let start = raw.index(raw.startIndex, offsetBy: i)
            let end = raw.index(start, offsetBy: min(6, raw.count - i))
            return String(raw[start..<end])
        }.joined(separator: "-")
    }

    /// Compact form without separators, for use in files and on the wire.
    public var compact: String { CrockfordBase32.encode(bytes) }

    /// Short prefix for log lines.
    public var short: String { String(compact.prefix(8)) }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(compact)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let id = DeviceID(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad device id \(s)")
        }
        self = id
    }
}

public struct Identity: Codable, Sendable {
    public var deviceID: DeviceID
    public var deviceName: String
    public var createdAt: Date

    /// The name this Mac answers to over mDNS, e.g. `Bitans-MacBook-Air` for `…local`.
    ///
    /// Read fresh each time rather than stored: it follows the Sharing settings, and a stale
    /// copy would send the other Mac looking for a name that no longer resolves.
    public static var localHostName: String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            return name
        }
        return Identity.mdnsName(from: Host.current().localizedName
                                 ?? ProcessInfo.processInfo.hostName)
    }

    /// How macOS turns a computer name into the name it answers to over mDNS.
    ///
    /// Spaces become hyphens, existing hyphens survive, and everything else is dropped —
    /// which is why "Bitan's MacBook Air" becomes "Bitans-MacBook-Air" and not
    /// "Bitan-s-MacBook-Air". Only a fallback: the real name is read from the system when
    /// available and sent across the link during the handshake.
    public static func mdnsName(from computerName: String) -> String {
        var out = ""
        for scalar in computerName.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" {
                out.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespaces.contains(scalar) {
                out.append("-")
            }
            // Anything else — apostrophes, punctuation, emoji — is dropped.
        }
        // Collapse runs of hyphens and trim them from the ends.
        return out.split(separator: "-").joined(separator: "-")
    }

    public init(deviceID: DeviceID, deviceName: String, createdAt: Date = Date()) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.createdAt = createdAt
    }

    /// Loads this machine's identity, creating and persisting one on first run.
    public static func loadOrCreate() throws -> Identity {
        try Paths.ensureSupportDirectory()
        let url = Paths.identityFile
        if let data = try? Data(contentsOf: url),
           let id = try? JSONDecoder.edgeJSON.decode(Identity.self, from: data) {
            return id
        }
        let fresh = Identity(deviceID: DeviceID(),
                             deviceName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                             createdAt: Date())
        try AtomicFile.write(try JSONEncoder.edgeJSON.encode(fresh), to: url, mode: 0o600)
        return fresh
    }
}

enum AtomicFile {
    /// Write-to-temp + rename, so a crash mid-write can never leave a half-written secrets file.
    static func write(_ data: Data, to url: URL, mode: Int16) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

public extension JSONEncoder {
    /// Stable, human-readable output: the state files are meant to be opened and read.
    static var edgeJSON: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

public extension JSONDecoder {
    static var edgeJSON: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
