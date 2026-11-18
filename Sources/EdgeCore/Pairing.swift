import Foundation
import CryptoKit

/// A pairing code short enough to read off one screen and type into another.
///
///     K7M2QR-9XZB4T-WPH5N3
///
/// 80 bits of secret plus an 8-bit checksum, as 18 Crockford base32 characters in three
/// groups of six. It started at 128 bits and 28 characters, which is a tiring thing to copy
/// by hand and bought nothing: the secret only has to resist an offline attack on a captured
/// handshake, and 2^80 is comfortably out of reach for that. Seven groups of four was the
/// kind of security decision that gets written down and then quietly worked around.
///
/// Codes in the old format are still accepted, so a pairing made before this still works.
public struct PairingCode: Sendable {
    public static let secretBytes = 10
    public static let legacySecretBytes = 16

    public let secret: Data

    public init(secret: Data) {
        precondition(secret.count == Self.secretBytes || secret.count == Self.legacySecretBytes)
        self.secret = secret
    }

    public static func generate() -> PairingCode {
        PairingCode(secret: Crypto.randomBytes(secretBytes))
    }

    private static func checksumByte<S: DataProtocol>(_ secret: S) -> UInt8 {
        var input = Data("edge/v1/checksum".utf8)
        input.append(contentsOf: secret)
        return Array(SHA256.hash(data: input))[0]
    }

    /// Characters of body for a given secret length: 8 bits in, 5 bits per character out.
    private static func bodyLength(forSecretBytes count: Int) -> Int {
        (count * 8 + 4) / 5
    }

    public var formatted: String {
        let body = CrockfordBase32.encode(secret)
        let sum  = CrockfordBase32.encode(Data([Self.checksumByte(secret)]))   // 2 chars
        let raw = body + sum
        let group = secret.count == Self.secretBytes ? 6 : 4
        return stride(from: 0, to: raw.count, by: group).map { i in
            let s = raw.index(raw.startIndex, offsetBy: i)
            let e = raw.index(s, offsetBy: min(group, raw.count - i))
            return String(raw[s..<e])
        }.joined(separator: "-")
    }

    public static func parse(_ input: String) throws -> PairingCode {
        // Forgiving on the way in: people paste codes with stray spaces, quotes and line
        // breaks, and none of that is their mistake to correct.
        let cleaned = input.filter { CrockfordBase32.isCodeCharacter($0) }

        let characters = Array(cleaned)
        let lengths = [secretBytes, legacySecretBytes]
        // Where each surviving character came from, so a window can be asked what surrounded
        // it before the punctuation was dropped.
        let origin = Array(input).enumerated()
            .filter { CrockfordBase32.isCodeCharacter($0.element) }
            .map(\.offset)
        let source = Array(input)

        /// Did this window start and end at a real break in the text?
        ///
        /// A code is normally pasted surrounded by spaces, quotes or line ends, and letters
        /// from the prose around it are themselves valid code characters — "code:" alone
        /// contributes four. Sliding a window over all of them and taking the first that
        /// checksums is right about 255 times in 256, and wrong the rest of the time: an
        /// 8-bit checksum passed by chance returns a code nobody typed. Requiring the window
        /// to sit between two breaks makes the overlapping near-misses impossible instead of
        /// merely unlikely.
        func isWholeWord(_ start: Int, _ end: Int) -> Bool {
            func isBreak(_ index: Int) -> Bool {
                guard index >= 0, index < source.count else { return true }
                return !CrockfordBase32.isCodeCharacter(source[index]) && source[index] != "-"
            }
            return isBreak(origin[start] - 1) && isBreak(origin[end - 1] + 1)
        }

        // Whole words first, then anything that checksums — a code typed straight into a
        // field with no surroundings at all has to keep working.
        for wholeWordsOnly in [true, false] {
            for secretCount in lengths {
                let total = bodyLength(forSecretBytes: secretCount) + 2
                guard characters.count >= total else { continue }
                for start in 0...(characters.count - total) {
                    if wholeWordsOnly, !isWholeWord(start, start + total) { continue }
                    let window = String(characters[start..<(start + total)])
                    if let code = decode(window, secretBytes: secretCount) { return code }
                }
            }
        }

        let wanted = lengths.map { bodyLength(forSecretBytes: $0) + 2 }
        if characters.count < wanted[0] {
            throw EdgeError.badPairingCode(
                "expected \(wanted[0]) characters, got \(characters.count)")
        }
        throw EdgeError.badPairingCode(
            "no valid code found in that text — check it for a typo")
    }

    /// Decodes an exact-length candidate, returning nil if the checksum disagrees.
    private static func decode(_ candidate: String, secretBytes count: Int) -> PairingCode? {
        let bodyStr = String(candidate.prefix(bodyLength(forSecretBytes: count)))
        let sumStr = String(candidate.suffix(2))
        guard let body = CrockfordBase32.decode(bodyStr), body.count >= count,
              let sum = CrockfordBase32.decode(sumStr), sum.count == 1 else { return nil }
        let secret = body.prefix(count)
        guard sum[sum.startIndex] == checksumByte(secret) else { return nil }
        return PairingCode(secret: Data(secret))
    }

    public var psk: Data { Crypto.derivePSK(fromSecret: secret) }
}
