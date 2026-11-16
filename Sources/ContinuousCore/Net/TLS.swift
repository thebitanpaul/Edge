import Foundation
import Network
import Security

/// A pre-shared key together with the public identifier that selects it during the TLS handshake.
public struct PSKEntry: Sendable {
    public let psk: Data
    public let keyID: Data

    public init(psk: Data) {
        self.psk = psk
        self.keyID = Crypto.deriveKeyID(fromPSK: psk)
    }
}

public enum TLSConfig {
    /// `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (RFC 7905).
    ///
    /// This is the only suite the link will accept, and the choice is deliberate:
    ///
    /// * **ECDHE** means every session gets a fresh ephemeral key. Someone who records the
    ///   traffic today and steals `secrets.json` next year still cannot decrypt what they
    ///   recorded — which matters a lot when the plaintext is your keystrokes.
    /// * **PSK** authenticates both ends from the pairing code, with no certificate
    ///   authority anywhere in the design.
    /// * **ChaCha20-Poly1305** is an AEAD, so there is no CBC padding oracle to worry about,
    ///   and it is constant-time in software on any Mac.
    ///
    /// Note on versions: Network.framework only wires external pre-shared keys into TLS 1.2.
    /// Pinning 1.3 makes the handshake fail outright — verified, not assumed. Restricted to
    /// one ECDHE+AEAD suite, TLS 1.2 has none of the weaknesses it is usually blamed for.
    public static let requiredCiphersuite: UInt16 = 0xCCAC

    /// Builds TLS parameters using external pre-shared keys.
    ///
    /// Several keys can be installed at once, each tagged with its own identifier, so a Mac
    /// paired with more than one machine still runs a single listener and the TLS stack picks
    /// the right key from the identity the client offers.
    public static func parameters(keys: [PSKEntry]) -> NWParameters {
        precondition(!keys.isEmpty, "TLS parameters need at least one pre-shared key")

        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        for entry in keys {
            let pskData = entry.psk.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = entry.keyID.withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(sec,
                                                    pskData as __DispatchData,
                                                    identity as __DispatchData)
        }

        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        if let suite = tls_ciphersuite_t(rawValue: requiredCiphersuite) {
            sec_protocol_options_append_tls_ciphersuite(sec, suite)
        } else {
            // Appending nothing would leave the default list in place, which includes
            // non-forward-secret PSK suites. Fail loudly instead of downgrading quietly.
            preconditionFailure("TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 is unavailable on this system")
        }

        let tcp = NWProtocolTCP.Options()
        // Input events are tiny and latency-critical; coalescing them would add up to 40 ms.
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5

        let params = NWParameters(tls: tls, tcp: tcp)
        params.serviceClass = .responsiveData
        // Keep traffic on real interfaces only; never let this ride a VPN or cellular tether.
        params.prohibitedInterfaceTypes = [.cellular]
        return params
    }

    /// Human-readable description of what the handshake actually negotiated, for `doctor`/`selftest`.
    public static func describeNegotiation(_ connection: NWConnection) -> String {
        guard let (version, suite) = negotiated(connection) else { return "unknown" }
        return "\(name(for: version)) / \(name(for: suite))"
    }

    public static func negotiated(_ connection: NWConnection) -> (tls_protocol_version_t, tls_ciphersuite_t)? {
        guard let md = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        let sec = md.securityProtocolMetadata
        return (sec_protocol_metadata_get_negotiated_tls_protocol_version(sec),
                sec_protocol_metadata_get_negotiated_tls_ciphersuite(sec))
    }

    /// Belt-and-braces downgrade check.
    ///
    /// The options above already request exactly one suite, so this should never fire. It
    /// exists because a silent downgrade to a non-forward-secret suite is precisely the kind
    /// of failure that is invisible until it matters.
    public static func verifyNegotiation(_ connection: NWConnection) -> String? {
        guard let (version, suite) = negotiated(connection) else {
            return "could not read the negotiated TLS parameters"
        }
        guard suite.rawValue == requiredCiphersuite else {
            return String(format: "negotiated ciphersuite 0x%04X instead of the required 0x%04X (forward secrecy would be lost)",
                          suite.rawValue, requiredCiphersuite)
        }
        guard version == .TLSv12 || version == .TLSv13 else {
            return "negotiated an unacceptable TLS version"
        }
        return nil
    }

    private static func name(for v: tls_protocol_version_t) -> String {
        switch v {
        case .TLSv13: return "TLS 1.3"
        case .TLSv12: return "TLS 1.2"
        case .DTLSv12: return "DTLS 1.2"
        default: return "TLS ?"
        }
    }

    private static func name(for c: tls_ciphersuite_t) -> String {
        switch c {
        case .AES_128_GCM_SHA256: return "AES-128-GCM-SHA256"
        case .AES_256_GCM_SHA384: return "AES-256-GCM-SHA384"
        case .CHACHA20_POLY1305_SHA256: return "CHACHA20-POLY1305-SHA256"
        default:
            if c.rawValue == requiredCiphersuite { return "ECDHE-PSK-CHACHA20-POLY1305-SHA256" }
            return String(format: "0x%04X", c.rawValue)
        }
    }
}

public enum NetworkAddress {
    /// Is this peer somewhere we are willing to accept a link from?
    ///
    /// Two tests, either of which is enough:
    ///
    /// * the address is in a range that cannot be routed in from the public internet, or
    /// * the address falls inside a subnet this Mac is directly attached to.
    ///
    /// The second test exists because of a case that shows up the moment you try this for
    /// real: with IPv6 enabled, Bonjour hands out the peer's *global* address alongside its
    /// link-local one, and a range-based check refuses the Mac sitting next to you. Comparing
    /// against our own interface prefixes accepts that machine while still refusing the
    /// internet at large.
    ///
    /// None of this is the actual security boundary — the pre-shared key is. This only limits
    /// who can make us do TLS work in the first place.
    public static func isAcceptablePeer(_ endpoint: NWEndpoint?) -> Bool {
        isPrivate(endpoint) || isOnDirectlyAttachedSubnet(endpoint)
    }

    /// True for loopback, RFC1918, CGNAT and link-local addresses.
    public static func isPrivate(_ endpoint: NWEndpoint?) -> Bool {
        guard let bytes = addressBytes(endpoint) else { return false }
        if bytes.count == 4 {
            if bytes == [127, 0, 0, 1] || bytes[0] == 127 { return true }
            if bytes[0] == 169 && bytes[1] == 254 { return true }          // link-local
            if bytes[0] == 10 { return true }
            if bytes[0] == 172 && (16...31).contains(bytes[1]) { return true }
            if bytes[0] == 192 && bytes[1] == 168 { return true }
            if bytes[0] == 100 && (64...127).contains(bytes[1]) { return true }  // CGNAT
            return false
        }
        if bytes.count == 16 {
            if bytes == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] { return true }  // ::1
            if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true }               // fe80::/10
            if (bytes[0] & 0xFE) == 0xFC { return true }                                   // fc00::/7
            return false
        }
        return false
    }

    /// True when the address shares a prefix with one of this Mac's own interfaces.
    public static func isOnDirectlyAttachedSubnet(_ endpoint: NWEndpoint?) -> Bool {
        guard let peer = addressBytes(endpoint) else { return false }
        for prefix in directlyAttachedPrefixes() where prefix.address.count == peer.count {
            var matches = true
            for i in 0..<peer.count where (peer[i] & prefix.mask[i]) != (prefix.address[i] & prefix.mask[i]) {
                matches = false
                break
            }
            // An all-zero mask would match everything; a misconfigured interface must not
            // silently turn the check off.
            if matches && prefix.mask.contains(where: { $0 != 0 }) { return true }
        }
        return false
    }

    struct InterfacePrefix {
        let address: [UInt8]
        let mask: [UInt8]
    }

    static func directlyAttachedPrefixes() -> [InterfacePrefix] {
        var result: [InterfacePrefix] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            defer { cursor = cur.pointee.ifa_next }
            guard Int32(cur.pointee.ifa_flags) & IFF_UP != 0 else { continue }
            guard let sa = cur.pointee.ifa_addr, let sm = cur.pointee.ifa_netmask else { continue }
            guard sa.pointee.sa_family == sm.pointee.sa_family else { continue }

            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let m = sm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                result.append(InterfacePrefix(address: withUnsafeBytes(of: a) { [UInt8]($0) },
                                              mask: withUnsafeBytes(of: m) { [UInt8]($0) }))
            case AF_INET6:
                let a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let m = sm.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                result.append(InterfacePrefix(address: withUnsafeBytes(of: a) { [UInt8]($0) },
                                              mask: withUnsafeBytes(of: m) { [UInt8]($0) }))
            default:
                continue
            }
        }
        return result
    }

    static func addressBytes(_ endpoint: NWEndpoint?) -> [UInt8]? {
        guard let endpoint, case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let v4): return [UInt8](v4.rawValue)
        case .ipv6(let v6): return [UInt8](v6.rawValue)
        case .name: return nil
        @unknown default: return nil
        }
    }

    /// True when the peer is this very machine. Distinct from the device-id check: two
    /// instances on one Mac with separate state directories have different identities but are
    /// still, physically, the same keyboard and the same screen.
    public static func isLoopback(_ endpoint: NWEndpoint?) -> Bool {
        guard let bytes = addressBytes(endpoint) else { return false }
        if bytes.count == 4 { return bytes[0] == 127 }
        if bytes.count == 16 { return bytes == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] }
        return false
    }

    public static func describe(_ endpoint: NWEndpoint?) -> String {
        guard let endpoint else { return "unknown" }
        switch endpoint {
        case .hostPort(let host, let port):
            var h = "\(host)"
            // Strip the %en0 scope suffix and bracket IPv6 so "fe80::1:52777" is not ambiguous.
            if let pct = h.firstIndex(of: "%") { h = String(h[h.startIndex..<pct]) }
            if h.contains(":") { h = "[\(h)]" }
            return "\(h):\(port.rawValue)"
        default:
            return "\(endpoint)"
        }
    }
}
