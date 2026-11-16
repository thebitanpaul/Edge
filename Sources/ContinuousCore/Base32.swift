import Foundation

/// Crockford base32: no `I`, `L`, `O` or `U`, so a pairing code read off one screen and typed
/// into another cannot be mangled by the usual 1/l/I and 0/O confusions.
public enum CrockfordBase32 {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private static let decodeTable: [Character: UInt8] = {
        var t: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() {
            t[c] = UInt8(i)
            if let lower = c.lowercased().first { t[lower] = UInt8(i) }
        }
        // Forgiving aliases for the characters the alphabet deliberately omits.
        t["O"] = 0; t["o"] = 0
        t["I"] = 1; t["i"] = 1; t["L"] = 1; t["l"] = 1
        t["U"] = 27; t["u"] = 27   // U -> V
        return t
    }()

    public static func encode(_ data: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                let idx = Int((buffer >> UInt32(bits - 5)) & 0x1F)
                out.append(alphabet[idx])
                bits -= 5
            }
        }
        if bits > 0 {
            let idx = Int((buffer << UInt32(5 - bits)) & 0x1F)
            out.append(alphabet[idx])
        }
        return out
    }

    public static func decode(_ string: String) -> Data? {
        var buffer: UInt32 = 0
        var bits = 0
        var out = Data()
        for ch in string {
            if ch == "-" || ch == " " { continue }
            guard let v = decodeTable[ch] else { return nil }
            buffer = (buffer << 5) | UInt32(v)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }
}
