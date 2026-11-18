import Testing
import Foundation
import Network
import Security
@testable import EdgeCore

// MARK: - Pairing codes

@Suite("Crockford base32")
struct Base32Tests {
    @Test("round-trips arbitrary data")
    func roundTrip() throws {
        for length in 0...40 {
            let data = Crypto.randomBytes(length)
            let encoded = CrockfordBase32.encode(data)
            let decoded = try #require(CrockfordBase32.decode(encoded))
            // Encoding pads up to a 5-bit boundary, so decoding may carry one extra byte.
            #expect(decoded.prefix(length) == data, "length \(length)")
        }
    }

    @Test("aliases the characters people mistype")
    func aliases() {
        #expect(CrockfordBase32.decode("O0") == CrockfordBase32.decode("00"))
        #expect(CrockfordBase32.decode("I1") == CrockfordBase32.decode("11"))
        #expect(CrockfordBase32.decode("L1") == CrockfordBase32.decode("11"))
    }

    @Test("ignores separators and whitespace")
    func separators() {
        #expect(CrockfordBase32.decode("ABCD-EFGH") == CrockfordBase32.decode("ABCDEFGH"))
        #expect(CrockfordBase32.decode("ABCD EFGH") == CrockfordBase32.decode("ABCDEFGH"))
    }

    @Test("rejects characters outside the alphabet")
    func rejectsJunk() {
        #expect(CrockfordBase32.decode("ABC!") == nil)
        #expect(CrockfordBase32.decode("ABC_") == nil)
    }
}

@Suite("Pairing codes")
struct PairingCodeTests {
    @Test("round-trips 200 generated codes")
    func roundTrip() throws {
        for _ in 0..<200 {
            let code = PairingCode.generate()
            #expect(try PairingCode.parse(code.formatted).secret == code.secret)
        }
    }

    @Test("formats as 7 groups of 4")
    func format() {
        let code = PairingCode(secret: Data(repeating: 0xAB, count: 16))
        #expect(code.formatted.filter { $0 != "-" }.count == 28)
        #expect(code.formatted.split(separator: "-").count == 7)
    }

    @Test("accepts lowercase, spaces and stray whitespace")
    func forgiving() throws {
        let code = PairingCode.generate()
        let messy = "  " + code.formatted.lowercased().replacingOccurrences(of: "-", with: " ") + "  "
        #expect(try PairingCode.parse(messy).secret == code.secret)
    }

    /// The checksum exists so that a mistyped code is reported as a typo rather than silently
    /// becoming a different key that then fails later with an opaque TLS error.
    @Test("catches almost every single-character typo")
    func catchesTypos() {
        var caught = 0, attempted = 0
        for _ in 0..<40 {
            let code = PairingCode.generate()
            var chars = Array(code.formatted)
            for i in chars.indices where chars[i] != "-" {
                let original = chars[i]
                guard let replacement = CrockfordBase32.alphabet.first(where: { $0 != original })
                else { continue }
                chars[i] = replacement
                attempted += 1
                do { _ = try PairingCode.parse(String(chars)) } catch { caught += 1 }
                chars[i] = original
            }
        }
        // An 8-bit checksum lets roughly 1 in 256 slip through; demand well above that.
        #expect(Double(caught) / Double(attempted) > 0.98, "caught \(caught) of \(attempted)")
    }

    @Test("rejects wrong lengths")
    func wrongLength() {
        #expect(throws: (any Error).self) { try PairingCode.parse("ABCD-EFGH") }
        #expect(throws: (any Error).self) { try PairingCode.parse("") }
    }
}

// MARK: - Key schedule

@Suite("Key schedule")
struct CryptoTests {
    @Test("derivation is deterministic and the keys are separated")
    func derivation() {
        let secret = Crypto.randomBytes(16)
        let psk = Crypto.derivePSK(fromSecret: secret)
        #expect(psk == Crypto.derivePSK(fromSecret: secret))
        #expect(psk.count == 32)

        let auth = Crypto.deriveAuthKey(fromPSK: psk)
        let keyID = Crypto.deriveKeyID(fromPSK: psk)
        #expect(auth != psk)
        #expect(keyID.count == Wire.keyIDLength)
        #expect(!auth.starts(with: keyID), "the public key id must not leak the auth key")
        #expect(!psk.starts(with: keyID), "the public key id must not leak the psk")
    }

    @Test("different secrets give different keys")
    func distinct() {
        #expect(Crypto.derivePSK(fromSecret: Crypto.randomBytes(16))
                != Crypto.derivePSK(fromSecret: Crypto.randomBytes(16)))
    }

    /// Every input to the proof must matter. If any of these were ignored, a proof captured
    /// from one session or one direction could be replayed into another.
    @Test("the handshake proof binds direction, both nonces and the device")
    func proofBinding() {
        let key = Crypto.randomBytes(32)
        let cn = Crypto.randomBytes(32), sn = Crypto.randomBytes(32)
        let a = DeviceID(), b = DeviceID()
        let base = Crypto.proof(authKey: key, direction: "d1", clientNonce: cn, serverNonce: sn, proverDeviceID: a)

        #expect(base.count == Wire.proofLength)
        #expect(base == Crypto.proof(authKey: key, direction: "d1", clientNonce: cn, serverNonce: sn, proverDeviceID: a))
        #expect(base != Crypto.proof(authKey: key, direction: "d2", clientNonce: cn, serverNonce: sn, proverDeviceID: a))
        #expect(base != Crypto.proof(authKey: key, direction: "d1", clientNonce: sn, serverNonce: cn, proverDeviceID: a))
        #expect(base != Crypto.proof(authKey: key, direction: "d1", clientNonce: cn, serverNonce: sn, proverDeviceID: b))
        #expect(base != Crypto.proof(authKey: Crypto.randomBytes(32), direction: "d1", clientNonce: cn, serverNonce: sn, proverDeviceID: a))
    }

    @Test("constant-time compare behaves like equality")
    func compare() {
        let a = Crypto.randomBytes(32)
        #expect(Crypto.constantTimeEquals(a, a))
        #expect(!Crypto.constantTimeEquals(a, Crypto.randomBytes(32)))
        #expect(!Crypto.constantTimeEquals(a, a.prefix(16)))
        #expect(Crypto.constantTimeEquals(Data(), Data()))
    }

    @Test("random bytes do not repeat")
    func randomness() {
        let samples = (0..<64).map { _ in Crypto.randomBytes(16) }
        #expect(Set(samples).count == samples.count)
    }
}

// MARK: - Wire protocol

@Suite("Wire protocol")
struct CodecTests {
    static let samples: [Message] = [
        .hello(protocolVersion: Wire.protocolVersion, deviceID: DeviceID(), deviceName: "Måc ünicode 🖱",
               hostName: "mac-unicode", role: .host, capabilities: .baseline,
               nonce: Crypto.randomBytes(32), keyID: Crypto.randomBytes(8)),
        .helloAck(protocolVersion: Wire.protocolVersion, deviceID: DeviceID(), deviceName: "",
                  hostName: "", capabilities: [.pointer], nonce: Crypto.randomBytes(32),
                  proof: Crypto.randomBytes(32)),
        .authProof(proof: Crypto.randomBytes(32)),
        .ready,
        .ping(seq: .max, sentAt: .max),
        .pong(seq: 0, sentAt: 0),
        .bye(reason: "done"),
        .failure(code: 7, message: "nope"),
        .enterScreen(x: .min, y: .max, flags: 0xDEAD_BEEF_CAFE_0000),
        .leaveScreen,
        .mouseMove(x: -1, y: -1, dx: .min, dy: .max),
        .mouseButton(button: .middle, down: false, clickCount: 3, x: 5, y: -5),
        .scroll(dx: -10, dy: 10, isPixel: false),
        .keyEvent(keyCode: 0xFFFF, down: true, isRepeat: true, flags: .max),
        .flagsChanged(flags: 0),
        .screenInfo(displays: []),
        .screenInfo(displays: (0..<4).map { Display(x: Int32($0), y: 0, width: 100, height: 100, isMain: $0 == 0) }),
        .clipboard(kind: "public.utf8-plain-text", payload: Data("hello".utf8)),
    ]

    @Test("every message type round-trips through a frame")
    func roundTrip() throws {
        for message in Self.samples {
            let frame = Codec.encodeFrame(message)
            let declared = Int(frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            #expect(declared == frame.count - 4, "length prefix for \(message.type)")

            let decoded = try Codec.decode(type: frame[4], payload: frame.dropFirst(5))
            #expect(decoded.type == message.type)
            #expect(Codec.encodePayload(decoded) == Codec.encodePayload(message),
                    "payload mismatch for \(message.type)")
        }
    }

    @Test("hello fields survive exactly")
    func helloFields() throws {
        let id = DeviceID()
        let nonce = Crypto.randomBytes(32)
        let keyID = Crypto.randomBytes(8)
        let frame = Codec.encodeFrame(.hello(protocolVersion: 1, deviceID: id, deviceName: "Work Mac",
                                             hostName: "work-mac", role: .client,
                                             capabilities: [.pointer, .clipboard],
                                             nonce: nonce, keyID: keyID))
        guard case let .hello(v, gotID, name, host, role, caps, gotNonce, gotKeyID) =
                try Codec.decode(type: frame[4], payload: frame.dropFirst(5)) else {
            Issue.record("decoded the wrong case"); return
        }
        #expect(v == 1)
        #expect(gotID == id)
        #expect(name == "Work Mac")
        #expect(host == "work-mac")
        #expect(role == .client)
        #expect(caps.rawValue == Capabilities([.pointer, .clipboard]).rawValue)
        #expect(gotNonce == nonce)
        #expect(gotKeyID == keyID)
    }

    @Test("unknown message types are rejected")
    func unknownType() {
        #expect(throws: (any Error).self) { try Codec.decode(type: 0xEE, payload: Data()) }
    }

    @Test("truncated payloads are rejected, never half-decoded")
    func truncation() {
        for message in Self.samples {
            let payload = Codec.encodePayload(message)
            guard payload.count > 1 else { continue }
            #expect(throws: (any Error).self, "\(message.type) accepted a truncated payload") {
                try Codec.decode(type: message.type.rawValue, payload: payload.dropLast())
            }
        }
    }

    @Test("invalid enum values are rejected")
    func invalidEnum() {
        var payload = Codec.encodePayload(.mouseButton(button: .left, down: true, clickCount: 1, x: 0, y: 0))
        payload[payload.startIndex] = 99
        #expect(throws: (any Error).self) {
            try Codec.decode(type: MessageType.mouseButton.rawValue, payload: payload)
        }
    }

    /// Latency budget: the events sent most often must stay a single small write.
    @Test("hot-path frames stay small")
    func hotPath() {
        #expect(Codec.encodeFrame(.mouseMove(x: 0, y: 0, dx: 0, dy: 0)).count <= 24)
        #expect(Codec.encodeFrame(.keyEvent(keyCode: 0, down: true, isRepeat: false, flags: 0)).count <= 20)
    }
}

@Suite("Binary buffers")
struct BinaryBufferTests {
    @Test("reads back exactly what was written")
    func roundTrip() throws {
        var w = BinaryWriter()
        w.u8(0xFF); w.bool(true); w.u16(0xBEEF); w.u32(0xDEAD_BEEF); w.u64(.max)
        w.i16(-2); w.i32(-70_000); w.f64(.pi); w.string("héllo"); w.blob(Data([1, 2, 3]))

        var r = BinaryReader(w.data)
        #expect(try r.u8() == 0xFF)
        #expect(try r.bool() == true)
        #expect(try r.u16() == 0xBEEF)
        #expect(try r.u32() == 0xDEAD_BEEF)
        #expect(try r.u64() == .max)
        #expect(try r.i16() == -2)
        #expect(try r.i32() == -70_000)
        #expect(try r.f64() == .pi)
        #expect(try r.string() == "héllo")
        #expect(try r.blob(3) == Data([1, 2, 3]))
        #expect(r.remaining == 0)
    }

    @Test("throws rather than reading past the end")
    func overrun() {
        var r = BinaryReader(Data([1, 2]))
        #expect(throws: (any Error).self) { try r.u32() }
    }
}

// MARK: - Identity and storage

@Suite("Device identity")
struct DeviceIDTests {
    @Test("string forms round-trip")
    func roundTrip() {
        let id = DeviceID()
        #expect(DeviceID(string: id.compact) == id)
        #expect(DeviceID(string: id.description) == id)   // the grouped form too
        #expect(id.short.count == 8)
    }

    @Test("rejects the wrong size")
    func wrongSize() {
        #expect(DeviceID(bytes: Data(repeating: 0, count: 15)) == nil)
        #expect(DeviceID(bytes: Data()) == nil)
        #expect(DeviceID(string: "ABC") == nil)
    }

    @Test("codable round-trip")
    func codable() throws {
        let id = DeviceID()
        let data = try JSONEncoder.edgeJSON.encode(["id": id])
        #expect(try JSONDecoder.edgeJSON.decode([String: DeviceID].self, from: data)["id"] == id)
    }
}

@Suite("mDNS names")
struct MDNSNameTests {
    /// The rule macOS actually uses, which matters because this is the fallback for finding
    /// the other Mac when Bonjour browsing is blocked.
    @Test("derives the name macOS would use")
    func derivation() {
        #expect(Identity.mdnsName(from: "Bitan's MacBook Air") == "Bitans-MacBook-Air")
        #expect(Identity.mdnsName(from: "Bitan\u{2019}s MacBook Air") == "Bitans-MacBook-Air")
        #expect(Identity.mdnsName(from: "NAV-LT-0416") == "NAV-LT-0416")
        #expect(Identity.mdnsName(from: "My  Mac!!") == "My-Mac")
        #expect(Identity.mdnsName(from: "  spaced  out  ") == "spaced-out")
        #expect(Identity.mdnsName(from: "MacBook") == "MacBook")
    }

    @Test("this Mac reports a usable hostname")
    func localHostName() {
        let name = Identity.localHostName
        #expect(!name.isEmpty)
        #expect(!name.contains(" "), "an mDNS label cannot contain spaces: '\(name)'")
    }
}

@Suite("Pairing directory")
struct PairingDirectoryTests {
    private func makeDirectory(_ labels: [String]) -> (PairingDirectory, [Pairing]) {
        var store = SecretStore()
        store.pairings = labels.map { Pairing(psk: Crypto.randomBytes(32), label: $0) }
        return (PairingDirectory(store: store, inMemory: true), store.pairings)
    }

    @Test("resolves keys by their public identifier")
    func resolve() {
        let (dir, pairings) = makeDirectory(["a", "b"])
        #expect(dir.psk(forKeyID: pairings[0].keyID) == pairings[0].psk)
        #expect(dir.psk(forKeyID: pairings[1].keyID) == pairings[1].psk)
        #expect(dir.psk(forKeyID: Crypto.randomBytes(8)) == nil)
    }

    /// The security property that makes a leaked pairing code survivable: once a pairing has
    /// been used, only that Mac can use it again.
    @Test("pins on first use, then refuses other Macs")
    func pinning() {
        let (dir, pairings) = makeDirectory(["work"])
        let first = DeviceID(), second = DeviceID()

        #expect(dir.authorize(deviceID: first, keyID: pairings[0].keyID))
        dir.note(peer: PeerInfo(deviceID: first, name: "Work Mac", hostName: "work-mac", role: .host,
                                capabilities: .baseline, endpoint: "10.0.0.2:52777",
                                tlsDescription: "test", keyID: pairings[0].keyID))

        #expect(dir.authorize(deviceID: first, keyID: pairings[0].keyID), "the pinned Mac keeps working")
        #expect(!dir.authorize(deviceID: second, keyID: pairings[0].keyID),
                "a different Mac with the same key must be refused")

        dir.allowRebind = true
        #expect(dir.authorize(deviceID: second, keyID: pairings[0].keyID),
                "--rebind must allow a deliberate move")
    }

    @Test("an unknown key is never authorized")
    func unknownKey() {
        let (dir, _) = makeDirectory(["work"])
        #expect(!dir.authorize(deviceID: DeviceID(), keyID: Crypto.randomBytes(8)))
    }

    @Test("records the peer name and endpoint on connect")
    func records() {
        let (dir, pairings) = makeDirectory(["work"])
        dir.note(peer: PeerInfo(deviceID: DeviceID(), name: "Personal", hostName: "personal", role: .client,
                                capabilities: .baseline, endpoint: "192.168.1.9:52777",
                                tlsDescription: "test", keyID: pairings[0].keyID))
        let stored = dir.snapshot.pairings[0]
        #expect(stored.peerName == "Personal")
        #expect(stored.lastEndpoint == "192.168.1.9:52777")
        #expect(stored.lastSeenAt != nil)
        #expect(stored.isBound)
    }

    @Test("an in-memory directory never touches the real secrets file")
    func inMemoryIsolation() throws {
        let before = try? Data(contentsOf: Paths.secretsFile)
        let (dir, pairings) = makeDirectory(["scratch"])
        dir.note(peer: PeerInfo(deviceID: DeviceID(), name: "x", hostName: "x", role: .host,
                                capabilities: .baseline, endpoint: "", tlsDescription: "",
                                keyID: pairings[0].keyID))
        let after = try? Data(contentsOf: Paths.secretsFile)
        #expect(before == after)
    }
}

@Suite("Secret store")
struct SecretStoreTests {
    @Test("matches a pairing by label, key id or device id — and refuses ambiguity")
    func matching() throws {
        var store = SecretStore()
        let a = Pairing(psk: Crypto.randomBytes(32), label: "work-mac")
        let b = Pairing(psk: Crypto.randomBytes(32), label: "personal-mac")
        store.pairings = [a, b]

        #expect(try store.index(matching: "work-mac") == 0)
        #expect(try store.index(matching: "personal") == 1)
        #expect(try store.index(matching: String(a.keyIDHex.prefix(6))) == 0)
        #expect(throws: (any Error).self) { try store.index(matching: "nothing-like-this") }
        #expect(throws: (any Error).self, "an ambiguous needle must not silently pick one") {
            try store.index(matching: "mac")
        }
    }

    @Test("refuses to load key material from a group- or world-readable file")
    func permissionCheck() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edge-test-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp.path)
        #expect(throws: (any Error).self) { try SecretStore.assertSecurePermissions(tmp) }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        try SecretStore.assertSecurePermissions(tmp)
    }
}

// MARK: - Networking

@Suite("Endpoint parsing")
struct EndpointParsingTests {
    private func hostPort(_ s: String) throws -> (String, UInt16) {
        guard case let .hostPort(h, p) = try LinkConnector.parseEndpoint(s, defaultPort: 52777) else {
            throw EdgeError.invalidArgument("not a host/port")
        }
        return ("\(h)", p.rawValue)
    }

    @Test("parses the forms people actually type")
    func forms() throws {
        #expect(try hostPort("192.168.1.5") == ("192.168.1.5", 52777))
        #expect(try hostPort("192.168.1.5:9000").1 == 9000)
        #expect(try hostPort("work.local").0 == "work.local")
        #expect(try hostPort("[fe80::1]:9000").1 == 9000)
        #expect(try hostPort("[fe80::1]").1 == 52777)
        #expect(throws: (any Error).self) { try LinkConnector.parseEndpoint("", defaultPort: 52777) }
    }
}

@Suite("Address classification")
struct PrivateAddressTests {
    private func endpoint(_ s: String) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(s), port: 52777)
    }

    @Test("accepts loopback, RFC1918, CGNAT and link-local")
    func accepts() {
        for address in ["127.0.0.1", "10.1.2.3", "192.168.0.1", "172.16.5.4", "172.31.255.255",
                        "169.254.3.4", "100.64.0.1", "::1", "fd12::1", "fe80::1"] {
            #expect(NetworkAddress.isPrivate(endpoint(address)), "\(address) should be private")
        }
    }

    @Test("rejects public addresses and the near-misses around 172.16/12")
    func rejects() {
        for address in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "1.1.1.1",
                        "2606:4700::1111", "example.com"] {
            #expect(!NetworkAddress.isPrivate(endpoint(address)), "\(address) should not be private")
        }
    }

    /// Regression guard for the case that broke the first real two-machine test: with IPv6
    /// on, Bonjour offers the peer's global address and a range-only check refuses the Mac
    /// sitting next to you.
    @Test("accepts an address on a subnet this Mac is attached to")
    func acceptsOwnSubnet() throws {
        let prefixes = NetworkAddress.directlyAttachedPrefixes()
        #expect(!prefixes.isEmpty, "a Mac always has at least a loopback interface")

        for prefix in prefixes where prefix.mask.contains(where: { $0 != 0 }) {
            // Build an address inside this prefix by keeping the network part and
            // setting the host part to a fixed value.
            var candidate = prefix.address
            for i in candidate.indices {
                candidate[i] = (prefix.address[i] & prefix.mask[i]) | (~prefix.mask[i] & 0x02)
            }
            let host: NWEndpoint.Host = candidate.count == 4
                ? .ipv4(IPv4Address(Data(candidate))!)
                : .ipv6(IPv6Address(Data(candidate))!)
            #expect(NetworkAddress.isOnDirectlyAttachedSubnet(.hostPort(host: host, port: 52777)),
                    "address built from one of our own prefixes should match it")
        }
    }

    @Test("a clearly remote address is still refused")
    func refusesRemote() {
        // 203.0.113.0/24 is TEST-NET-3: reserved for documentation, never on a real LAN.
        #expect(!NetworkAddress.isAcceptablePeer(endpoint("203.0.113.47")))
        #expect(!NetworkAddress.isAcceptablePeer(endpoint("8.8.8.8")))
    }

    @Test("loopback and link-local stay acceptable")
    func acceptsLocal() {
        #expect(NetworkAddress.isAcceptablePeer(endpoint("127.0.0.1")))
        #expect(NetworkAddress.isAcceptablePeer(endpoint("::1")))
        #expect(NetworkAddress.isAcceptablePeer(endpoint("fe80::1")))
    }

    /// Guards the refusal to share input with ourselves: injected events would re-enter the
    /// tap that produced them.
    @Test("loopback is recognised whatever else an address looks like")
    func loopbackDetection() {
        #expect(NetworkAddress.isLoopback(endpoint("127.0.0.1")))
        #expect(NetworkAddress.isLoopback(endpoint("127.1.2.3")))
        #expect(NetworkAddress.isLoopback(endpoint("::1")))
        #expect(!NetworkAddress.isLoopback(endpoint("192.168.1.5")))
        #expect(!NetworkAddress.isLoopback(endpoint("fe80::1")))
        #expect(!NetworkAddress.isLoopback(nil))
    }

    /// Guards the ordering that decides which link a reconnection lands on: a remembered
    /// cable address is tried ahead of any hostname, and a hostname can only ever be the
    /// routed network. Mistaking one for the other is how a 2 ms link quietly became 200 ms.
    @Test("a remembered endpoint is recognised as a cable, port and brackets or not")
    func cableEndpoints() {
        #expect(NetworkAddress.isCableEndpoint("169.254.3.4"))
        #expect(NetworkAddress.isCableEndpoint("169.254.3.4:52777"))
        #expect(!NetworkAddress.isCableEndpoint("192.168.1.5"))
        #expect(!NetworkAddress.isCableEndpoint("192.168.1.5:52777"))
        #expect(!NetworkAddress.isCableEndpoint("work-mac.local:52777"))
        // An IPv6 literal is never a cable address here: the cable carries a self-assigned
        // IPv4, and the brackets must not be mistaken for a host:port split.
        #expect(!NetworkAddress.isCableEndpoint("[fe80::1]:52777"))
        #expect(!NetworkAddress.isCableEndpoint("fe80::1"))
    }

    @Test("IPv6 endpoints are rendered unambiguously")
    func formatting() {
        #expect(NetworkAddress.describe(endpoint("fe80::1")) == "[fe80::1]:52777")
        #expect(NetworkAddress.describe(endpoint("192.168.1.5")) == "192.168.1.5:52777")
    }
}

@Suite("TLS policy")
struct TLSPolicyTests {
    /// Guards the decision documented in TLS.swift. If this suite ever disappears from the
    /// platform the build must fail here rather than silently downgrade at runtime.
    @Test("the forward-secret PSK suite is available and is what we pin")
    func suiteAvailable() {
        #expect(TLSConfig.requiredCiphersuite == 0xCCAC, "TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256")
        #expect(tls_ciphersuite_t(rawValue: TLSConfig.requiredCiphersuite) != nil)
    }

    @Test("parameters build with several distinct keys")
    func multipleKeys() {
        let keys = (0..<3).map { _ in PSKEntry(psk: Crypto.randomBytes(32)) }
        #expect(Set(keys.map(\.keyID)).count == 3, "key identifiers must be distinct")
        _ = TLSConfig.parameters(keys: keys)
    }
}

@Suite("Files across the edge")
struct FileTransferTests {

    /// The sender has already proven it holds the pairing key, so this is not what keeps
    /// strangers out. It is what stops a name — awkward, or from a buggy sender — writing
    /// outside the folder the files are meant to land in.
    @Test("an incoming name cannot escape its folder")
    func namesAreContained() {
        #expect(FileTransfer.safeName("report.pdf") == "report.pdf")
        #expect(!FileTransfer.safeName("../../etc/passwd").contains("/"))
        #expect(!FileTransfer.safeName("/etc/passwd").contains("/"))
        #expect(FileTransfer.safeName("..") == "Received file")
        #expect(FileTransfer.safeName(".") == "Received file")
        #expect(FileTransfer.safeName("   ") == "Received file")
        #expect(FileTransfer.safeName(String(repeating: "a", count: 400)).count <= 255)
    }

    @Test("a second file of the same name does not overwrite the first")
    func namesAreUnique() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("edge-test-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let first = FileTransfer.uniqueURL(for: "notes.txt", in: dir)
        #expect(first.lastPathComponent == "notes.txt")
        fm.createFile(atPath: first.path, contents: Data("one".utf8))

        let second = FileTransfer.uniqueURL(for: "notes.txt", in: dir)
        #expect(second.lastPathComponent == "notes 2.txt")
        fm.createFile(atPath: second.path, contents: Data("two".utf8))

        #expect(FileTransfer.uniqueURL(for: "notes.txt", in: dir).lastPathComponent == "notes 3.txt")
        // An extensionless name still gets a number rather than a dot.
        #expect(FileTransfer.uniqueURL(for: "README", in: dir).lastPathComponent == "README")
    }

    @Test("every file message round-trips through the codec")
    func messagesRoundTrip() throws {
        let payload = Data((0..<2048).map { UInt8($0 % 251) })
        let messages: [Message] = [
            .fileOffer(transfer: 99, files: [FileEntry(name: "a file.txt", size: 2048),
                                             FileEntry(name: "empty", size: 0)]),
            .fileChunk(transfer: 99, index: 0, data: payload),
            .fileEnd(transfer: 99, ok: false, message: "the link closed"),
            .fileRequest,
        ]
        for message in messages {
            let frame = Codec.encodeFrame(message)
            let decoded = try Codec.decode(type: frame[frame.startIndex + 4],
                                           payload: Data(frame.dropFirst(5)))
            #expect(decoded.type == message.type)
            #expect(Codec.encodePayload(decoded) == Codec.encodePayload(message))
        }
    }

    /// Guards the cap: a drag of something enormous must be refused rather than tying the
    /// link up, and a count beyond the limit must not be decodable at all.
    @Test("a transfer of too many files is refused by the decoder")
    func tooManyFilesRejected() {
        var w = BinaryWriter()
        w.u32(1)
        w.u8(UInt8(FileLimits.maxFiles + 1))
        for i in 0...FileLimits.maxFiles {
            w.string("f\(i)"); w.u64(1)
        }
        #expect(throws: (any Error).self) {
            try Codec.decode(type: MessageType.fileOffer.rawValue, payload: w.data)
        }
    }
}
