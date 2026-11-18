import Foundation

/// Big-endian binary writer. Deliberately tiny: the hot path (a mouse move) must not
/// allocate beyond one small Data.
public struct BinaryWriter {
    public private(set) var data: Data

    public init(capacity: Int = 32) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    public mutating func u8(_ v: UInt8)   { data.append(v) }
    public mutating func bool(_ v: Bool)  { data.append(v ? 1 : 0) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func i16(_ v: Int16)  { u16(UInt16(bitPattern: v)) }
    public mutating func i32(_ v: Int32)  { u32(UInt32(bitPattern: v)) }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }

    /// Fixed-length blob; the length is implied by the schema, not written.
    public mutating func blob(_ v: Data) { data.append(v) }

    /// UTF-8 string with a u16 length prefix.
    public mutating func string(_ v: String) {
        let bytes = Data(v.utf8)
        precondition(bytes.count <= Int(UInt16.max))
        u16(UInt16(bytes.count))
        data.append(bytes)
    }
}

public struct BinaryReader {
    private let bytes: [UInt8]
    private var offset: Int = 0

    public init(_ data: Data) { bytes = [UInt8](data) }

    public var remaining: Int { bytes.count - offset }

    public enum Failure: Error, CustomStringConvertible {
        case truncated(need: Int, have: Int)
        case invalidUTF8
        case invalidValue(String)

        public var description: String {
            switch self {
            case .truncated(let n, let h): return "truncated payload (need \(n) more bytes, have \(h))"
            case .invalidUTF8: return "invalid UTF-8 in string field"
            case .invalidValue(let s): return "invalid value: \(s)"
            }
        }
    }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard remaining >= n else { throw Failure.truncated(need: n, have: remaining) }
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }

    public mutating func u8() throws -> UInt8 { try take(1).first! }
    public mutating func bool() throws -> Bool { try u8() != 0 }

    public mutating func u16() throws -> UInt16 {
        let s = try take(2)
        return s.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    public mutating func u32() throws -> UInt32 {
        let s = try take(4)
        return s.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    public mutating func u64() throws -> UInt64 {
        let s = try take(8)
        return s.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    public mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    public mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    public mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    public mutating func blob(_ n: Int) throws -> Data { Data(try take(n)) }

    public mutating func string() throws -> String {
        let n = Int(try u16())
        let raw = try take(n)
        guard let s = String(bytes: raw, encoding: .utf8) else { throw Failure.invalidUTF8 }
        return s
    }
}
