import Foundation
import CryptoKit

/// Key schedule and handshake proofs.
///
/// A pairing code carries 128 bits of entropy. Everything else is derived from it with
/// HKDF-SHA256 so that the TLS pre-shared key and the application-layer authentication key
/// are cryptographically independent: compromising one does not reveal the other.
public enum Crypto {
    public static let pskSalt  = Data("continuous/v1/psk".utf8)
    public static let authSalt = Data("continuous/v1/auth".utf8)
    /// PSK identity hint sent in the TLS handshake. Deliberately carries no device information.
    public static let pskIdentity = Data("continuous/v1".utf8)

    public static func randomBytes(_ count: Int) -> Data {
        var d = Data(count: count)
        let status = d.withUnsafeMutableBytes { buf -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, count, buf.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        return d
    }

    static func hkdf(ikm: Data, salt: Data, info: String, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                         salt: salt,
                                         info: Data(info.utf8),
                                         outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    /// 32-byte TLS pre-shared key derived from the pairing secret.
    public static func derivePSK(fromSecret secret: Data) -> Data {
        hkdf(ikm: secret, salt: pskSalt, info: "pre-shared-key", length: 32)
    }

    /// 32-byte key used only for the in-band challenge/response, derived from the PSK.
    public static func deriveAuthKey(fromPSK psk: Data) -> Data {
        hkdf(ikm: psk, salt: authSalt, info: "handshake", length: 32)
    }

    /// Binds the proof to the direction, both nonces, and the prover's device id, so a proof
    /// captured in one direction or one session cannot be replayed in another.
    public static func proof(authKey: Data,
                             direction: String,
                             clientNonce: Data,
                             serverNonce: Data,
                             proverDeviceID: DeviceID) -> Data {
        var msg = Data(direction.utf8)
        msg.append(clientNonce)
        msg.append(serverNonce)
        msg.append(proverDeviceID.bytes)
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: authKey))
        return Data(mac)
    }

    /// Length-independent, data-independent comparison.
    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }

    public static func fingerprint(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(4).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

public extension Crypto {
    static let keyIDSalt = Data("continuous/v1/keyid".utf8)

    /// Public, non-secret identifier for a pre-shared key.
    ///
    /// Sent in the clear as the TLS PSK identity so a listener that is paired with several
    /// Macs can pick the right key without trial decryption. Derived through HKDF rather
    /// than being a plain hash of the PSK, so it reveals nothing useful about the key.
    static func deriveKeyID(fromPSK psk: Data) -> Data {
        hkdf(ikm: psk, salt: keyIDSalt, info: "key-identifier", length: Wire.keyIDLength)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
