import Foundation
import CryptoKit

/// A human-typeable pairing code: 128 bits of secret plus an 8-bit checksum,
/// rendered as 28 Crockford base32 characters in groups of four.
///
///     G3K9-7QMW-X2ZB-4HTR-5NPD-J8VC-AY
public struct PairingCode: Sendable {
    public let secret: Data        // 16 bytes

    public init(secret: Data) {
        precondition(secret.count == 16)
        self.secret = secret
    }

    public static func generate() -> PairingCode {
        PairingCode(secret: Crypto.randomBytes(16))
    }

    private static func checksumByte(_ secret: Data) -> UInt8 {
        var input = Data("continuous/v1/checksum".utf8)
        input.append(secret)
        return Array(SHA256.hash(data: input))[0]
    }

    public var formatted: String {
        let body = CrockfordBase32.encode(secret)                          // 26 chars
        let sum  = CrockfordBase32.encode(Data([Self.checksumByte(secret)])) // 2 chars
        let raw = body + sum                                                // 28 chars
        return stride(from: 0, to: raw.count, by: 4).map { i in
            let s = raw.index(raw.startIndex, offsetBy: i)
            let e = raw.index(s, offsetBy: min(4, raw.count - i))
            return String(raw[s..<e])
        }.joined(separator: "-")
    }

    public static func parse(_ input: String) throws -> PairingCode {
        let cleaned = input.filter { $0 != "-" && !$0.isWhitespace }
        guard cleaned.count == 28 else {
            throw ContinuousError.badPairingCode("expected 28 characters, got \(cleaned.count)")
        }
        let bodyStr = String(cleaned.prefix(26))
        let sumStr  = String(cleaned.suffix(2))
        guard let body = CrockfordBase32.decode(bodyStr), body.count == 16,
              let sum = CrockfordBase32.decode(sumStr), sum.count == 1 else {
            throw ContinuousError.badPairingCode("contains characters outside the code alphabet")
        }
        guard sum[sum.startIndex] == checksumByte(body) else {
            throw ContinuousError.badPairingCode("checksum mismatch — re-check the code for a typo")
        }
        return PairingCode(secret: body)
    }

    public var psk: Data { Crypto.derivePSK(fromSecret: secret) }
}
