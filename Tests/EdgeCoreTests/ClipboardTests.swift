import Testing
import Foundation
import AppKit
import Network
import CryptoKit
@testable import EdgeCore

@Suite("Clipboard")
struct ClipboardTests {
    private func sample(_ text: String) -> ClipboardContents {
        ClipboardContents(representations: [
            .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8)),
        ])
    }

    @Test("contents survive the wire format")
    func roundTrip() throws {
        let original = ClipboardContents(representations: [
            .init(type: "public.rtf", data: Data(repeating: 7, count: 300)),
            .init(type: "public.utf8-plain-text", data: Data("héllo 🖱".utf8)),
        ])
        let decoded = try ClipboardContents.decode(original.encoded(), limit: 1 << 20)
        #expect(decoded == original)
    }

    @Test("empty contents round-trip")
    func empty() throws {
        let decoded = try ClipboardContents.decode(ClipboardContents(representations: []).encoded(),
                                                   limit: 1 << 20)
        #expect(decoded.isEmpty)
    }

    /// A peer is authenticated but that is not the same as trusted with unbounded memory.
    @Test("an oversized payload is refused rather than allocated")
    func refusesOversize() {
        let big = ClipboardContents(representations: [
            .init(type: "public.png", data: Data(repeating: 0, count: 5000)),
        ])
        #expect(throws: (any Error).self) {
            try ClipboardContents.decode(big.encoded(), limit: 1024)
        }
    }

    @Test("truncated payloads are refused")
    func refusesTruncated() {
        let encoded = sample("hello").encoded()
        #expect(throws: (any Error).self) {
            try ClipboardContents.decode(encoded.dropLast(3), limit: 1 << 20)
        }
    }

    /// The summary goes into logs and the menu, so it must describe the clipboard without
    /// quoting it — what you last copied is frequently a password.
    @Test("the summary never contains the clipboard itself")
    func summaryIsNotTheContent() {
        let secret = "correct-horse-battery-staple"
        let summary = sample(secret).summary
        #expect(!summary.contains(secret))
        #expect(summary.contains("text"))
    }

    @Test("reads and applies through a private pasteboard")
    func readWriteRoundTrip() throws {
        let board = try #require(NSPasteboard(name: .init("app.edge.tests.\(UUID().uuidString)")))
        defer { board.releaseGlobally() }
        let sync = ClipboardSync(pasteboard: board)

        board.clearContents()
        board.setString("from this Mac", forType: .string)
        let read = try #require(sync.read())
        #expect(read.representations.contains { $0.type == NSPasteboard.PasteboardType.string.rawValue })

        sync.apply(sample("from the other Mac"))
        #expect(board.string(forType: .string) == "from the other Mac")
    }

    /// Applying the peer's clipboard must not look like a local change, or the two Macs hand
    /// the same clipboard back and forth for ever.
    @Test("applying the peer's clipboard does not echo back")
    func noEchoLoop() throws {
        let board = try #require(NSPasteboard(name: .init("app.edge.tests.\(UUID().uuidString)")))
        defer { board.releaseGlobally() }
        let sync = ClipboardSync(pasteboard: board)

        var sends = 0
        sync.onLocalChange = { _ in sends += 1 }
        sync.apply(sample("from the other Mac"))
        sync.pollForTesting()
        #expect(sends == 0, "applying a remote clipboard was re-sent as a local change")

        // A genuine local change still goes out.
        board.clearContents()
        board.setString("typed here", forType: .string)
        sync.pollForTesting()
        #expect(sends == 1)
    }

    @Test("capabilities advertise the clipboard only when it is on")
    func capabilityGating() {
        var config = Config()
        #expect(!config.capabilities.contains(.clipboard))
        config.clipboardSharing = true
        #expect(config.capabilities.contains(.clipboard))
        #expect(config.capabilities.contains(.pointer))
    }
}

@Suite("Pairing identity")
struct PairingIdentityTests {
    /// Both Macs name a new pairing locally and identically, so two machines each showed
    /// "Mac 1" and neither said anything about the other.
    @Test("generated labels are recognised as generated")
    func generatedLabels() {
        func pairing(_ label: String) -> Pairing {
            Pairing(psk: Crypto.randomBytes(32), label: label)
        }
        #expect(pairing("Mac 1").hasGeneratedLabel)
        #expect(pairing("Mac 17").hasGeneratedLabel)
        #expect(pairing("pairing-4f2a").hasGeneratedLabel)
        #expect(!pairing("Work Mac").hasGeneratedLabel)
        #expect(!pairing("Mac mini in the study").hasGeneratedLabel)
        #expect(!pairing("MacBook 1 Pro").hasGeneratedLabel)
    }

    @Test("a generated label gives way to the peer's real name on first connection")
    func adoptsPeerName() {
        var store = SecretStore()
        store.pairings = [Pairing(psk: Crypto.randomBytes(32), label: "Mac 1")]
        let directory = PairingDirectory(store: store, inMemory: true)

        directory.note(peer: PeerInfo(deviceID: DeviceID(), name: "NAV-LT-0416",
                                      hostName: "NAV-LT-0416", role: .client,
                                      capabilities: .baseline, endpoint: "192.168.1.8:52777",
                                      tlsDescription: "test", keyID: store.pairings[0].keyID))
        #expect(directory.snapshot.pairings[0].label == "NAV-LT-0416")
    }

    @Test("a name you chose is never overwritten")
    func keepsChosenName() {
        var store = SecretStore()
        store.pairings = [Pairing(psk: Crypto.randomBytes(32), label: "Work Mac")]
        let directory = PairingDirectory(store: store, inMemory: true)

        directory.note(peer: PeerInfo(deviceID: DeviceID(), name: "NAV-LT-0416",
                                      hostName: "NAV-LT-0416", role: .client,
                                      capabilities: .baseline, endpoint: "", tlsDescription: "",
                                      keyID: store.pairings[0].keyID))
        #expect(directory.snapshot.pairings[0].label == "Work Mac")
        #expect(directory.snapshot.pairings[0].peerName == "NAV-LT-0416")
    }

    /// Renaming must not create two pairings that cannot be told apart when choosing one.
    @Test("an adopted name never collides with an existing one")
    func avoidsCollision() {
        var store = SecretStore()
        store.pairings = [Pairing(psk: Crypto.randomBytes(32), label: "NAV-LT-0416"),
                          Pairing(psk: Crypto.randomBytes(32), label: "Mac 2")]
        let directory = PairingDirectory(store: store, inMemory: true)

        directory.note(peer: PeerInfo(deviceID: DeviceID(), name: "NAV-LT-0416",
                                      hostName: "", role: .client, capabilities: .baseline,
                                      endpoint: "", tlsDescription: "",
                                      keyID: store.pairings[1].keyID))
        #expect(directory.snapshot.pairings[1].label == "Mac 2", "should not take a taken name")
        #expect(Set(directory.snapshot.pairings.map(\.label)).count == 2)
    }

    @Test("a manual address survives a save and load")
    func manualAddress() throws {
        var pairing = Pairing(psk: Crypto.randomBytes(32), label: "Work Mac")
        pairing.manualEndpoint = "192.168.1.42:52777"
        var store = SecretStore()
        store.pairings = [pairing]
        let data = try JSONEncoder.edgeJSON.encode(store)
        let back = try JSONDecoder.edgeJSON.decode(SecretStore.self, from: data)
        #expect(back.pairings[0].manualEndpoint == "192.168.1.42:52777")
    }
}

@Suite("Short pairing codes")
struct ShortPairingCodeTests {
    @Test("new codes are 18 characters in three groups")
    func shape() {
        let code = PairingCode.generate()
        #expect(code.secret.count == 10)
        #expect(code.formatted.filter { $0 != "-" }.count == 18)
        #expect(code.formatted.split(separator: "-").count == 3)
        #expect(code.formatted.count == 20)
    }

    @Test("round-trips 300 generated codes")
    func roundTrip() throws {
        for _ in 0..<300 {
            let code = PairingCode.generate()
            #expect(try PairingCode.parse(code.formatted).secret == code.secret)
        }
    }

    /// Pairings made before the code got shorter must keep working.
    @Test("the old 28-character format is still accepted")
    func legacyFormat() throws {
        let legacy = PairingCode(secret: Data(repeating: 0xAB, count: 16))
        #expect(legacy.formatted.filter { $0 != "-" }.count == 28)
        let parsed = try PairingCode.parse(legacy.formatted)
        #expect(parsed.secret == legacy.secret)
        #expect(parsed.psk == legacy.psk)
    }

    /// Codes get pasted out of messages, mail and terminals, and arrive wrapped in whatever
    /// that medium added. None of that is the typist's mistake to correct.
    @Test("a pasted code survives the mess around it")
    func forgivingPaste() throws {
        let code = PairingCode.generate()
        for messy in ["  \(code.formatted)  ",
                      code.formatted.lowercased(),
                      "\"\(code.formatted)\"",
                      code.formatted.replacingOccurrences(of: "-", with: " "),
                      "code: \(code.formatted)\n"] {
            #expect(try PairingCode.parse(messy).secret == code.secret, "failed on: \(messy)")
        }
    }

    @Test("a typo is still caught")
    func catchesTypos() {
        var caught = 0, tried = 0
        for _ in 0..<60 {
            let code = PairingCode.generate()
            var chars = Array(code.formatted)
            for i in chars.indices where chars[i] != "-" {
                let original = chars[i]
                guard let other = CrockfordBase32.alphabet.first(where: { $0 != original })
                else { continue }
                chars[i] = other
                tried += 1
                do { _ = try PairingCode.parse(String(chars)) } catch { caught += 1 }
                chars[i] = original
            }
        }
        #expect(Double(caught) / Double(tried) > 0.98, "caught \(caught) of \(tried)")
    }

    @Test("still far beyond brute force")
    func entropy() {
        // 10 bytes is 80 bits. The secret only has to resist an offline attack on a captured
        // handshake; 2^80 is not a thing anyone is doing to borrow a keyboard.
        #expect(PairingCode.secretBytes * 8 == 80)
        #expect(Set((0..<200).map { _ in PairingCode.generate().secret }).count == 200)
    }
}

@Suite("Choosing which Mac to dial")
struct PeerSelectionTests {
    private func peer(_ name: String, _ id: DeviceID?) -> DiscoveredPeer {
        DiscoveredPeer(serviceName: name, deviceID: id, role: "client",
                       endpoint: .hostPort(host: NWEndpoint.Host("\(name).local"), port: 52777))
    }

    /// The bug this exists for: a pairing that has never connected has no peer device id,
    /// because the id is learned *from* the first handshake. Matching on one could only fail,
    /// so a fresh pairing could never be found however well Bonjour was working.
    @Test("an unbound pairing dials whatever is advertising")
    func unboundUsesAnything() {
        let found = [peer("NAV-LT-0416", DeviceID())]
        let chosen = PeerSelection.choose(from: found, boundTo: nil, excluding: DeviceID())
        #expect(chosen?.serviceName == "NAV-LT-0416")
    }

    @Test("a bound pairing dials only the Mac it is pinned to")
    func boundIsStrict() {
        let wanted = DeviceID()
        let found = [peer("Someone Else", DeviceID()), peer("Work Mac", wanted)]
        #expect(PeerSelection.choose(from: found, boundTo: wanted, excluding: nil)?
                    .serviceName == "Work Mac")
        // Pinned to a Mac that is not here: dial nothing rather than the wrong one.
        #expect(PeerSelection.choose(from: [peer("Someone Else", DeviceID())],
                                     boundTo: wanted, excluding: nil) == nil)
    }

    /// A Mac that both advertises and dials would otherwise find its own service.
    @Test("never dials itself")
    func excludesSelf() {
        let me = DeviceID()
        #expect(PeerSelection.choose(from: [peer("Me", me)], boundTo: nil, excluding: me) == nil)

        let other = DeviceID()
        let chosen = PeerSelection.choose(from: [peer("Me", me), peer("Them", other)],
                                          boundTo: nil, excluding: me)
        #expect(chosen?.serviceName == "Them")
    }

    @Test("several unknown Macs each get a turn")
    func rotatesCandidates() {
        let found = [peer("A", DeviceID()), peer("B", DeviceID()), peer("C", DeviceID())]
        let names = (1...6).map {
            PeerSelection.choose(from: found, boundTo: nil, excluding: nil, attempt: $0)?.serviceName
        }
        #expect(names == ["A", "B", "C", "A", "B", "C"])
    }

    @Test("nothing advertising means nothing chosen")
    func emptyIsNil() {
        #expect(PeerSelection.choose(from: [], boundTo: nil, excluding: DeviceID()) == nil)
    }

    @Test("a peer with no device id in its advert is still dialable when unbound")
    func missingIdStillUsable() {
        let chosen = PeerSelection.choose(from: [peer("Mystery", nil)],
                                          boundTo: nil, excluding: DeviceID())
        #expect(chosen?.serviceName == "Mystery")
    }
}

@Suite("Pairing over the network")
struct NetworkPairingTests {
    /// The property that makes this worth having: both Macs necessarily end up with the same
    /// key, where two people typing a code can end up with two different ones and no sign of it.
    @Test("both sides derive the same key")
    func sharedKeyMatches() throws {
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()

        let secretA = try a.sharedSecretFromKeyAgreement(with: b.publicKey)
        let secretB = try b.sharedSecretFromKeyAgreement(with: a.publicKey)

        let keyA = NetworkPairing.derivePSK(from: secretA)
        let keyB = NetworkPairing.derivePSK(from: secretB)
        #expect(keyA == keyB)
        #expect(keyA.count == 32)
        #expect(Crypto.deriveKeyID(fromPSK: keyA) == Crypto.deriveKeyID(fromPSK: keyB))
    }

    /// Both Macs must show the same number whichever of them dialled, or the person comparing
    /// them is told the pairing failed when it did not.
    @Test("the verification number does not depend on who dialled")
    func verificationIsSymmetric() {
        for _ in 0..<50 {
            let a = Curve25519.KeyAgreement.PrivateKey().publicKey
            let b = Curve25519.KeyAgreement.PrivateKey().publicKey
            let forward = NetworkPairing.verificationDigits(a, b)
            let backward = NetworkPairing.verificationDigits(b, a)
            #expect(forward == backward)
            #expect(forward.count == 6)
            let allDigits = forward.allSatisfy { $0.isNumber }
            #expect(allDigits)
        }
    }

    /// A machine in the middle substitutes its own keys, which gives a different number on
    /// each side. That only helps if the numbers are spread out.
    @Test("different exchanges give different numbers")
    func verificationIsWellSpread() {
        let digits = (0..<400).map { _ in
            NetworkPairing.verificationDigits(Curve25519.KeyAgreement.PrivateKey().publicKey,
                                              Curve25519.KeyAgreement.PrivateKey().publicKey)
        }
        // With a million possibilities, 400 draws should essentially never repeat.
        #expect(Set(digits).count >= 399)
    }

    @Test("hello messages round-trip")
    func helloRoundTrip() throws {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey
        let encoded = NetworkPairing.encodeHello(publicKey: key, name: "Bitan's MacBook Air")
        let (decodedKey, name) = try NetworkPairing.decodeHello(encoded)
        #expect(decodedKey.rawRepresentation == key.rawRepresentation)
        #expect(name == "Bitan's MacBook Air")
    }

    @Test("a malformed hello is refused, not guessed at")
    func rejectsMalformed() {
        #expect(throws: (any Error).self) { try NetworkPairing.decodeHello(Data()) }
        #expect(throws: (any Error).self) { try NetworkPairing.decodeHello(Data([9, 1])) }
        #expect(throws: (any Error).self) {
            try NetworkPairing.decodeHello(Data([1, 1] + [UInt8](repeating: 0, count: 4)))
        }
    }

    @Test("the derived key works as a pairing key like any other")
    func derivedKeyIsUsable() throws {
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        let secret = try a.sharedSecretFromKeyAgreement(with: b.publicKey)
        let psk = NetworkPairing.derivePSK(from: secret)
        let pairing = Pairing(psk: psk, label: "Work Mac")
        #expect(pairing.keyID.count == Wire.keyIDLength)
        #expect(!pairing.hasGeneratedLabel)
        _ = TLSConfig.parameters(keys: [PSKEntry(psk: psk)])
    }
}

@Suite("Pairings that have never been used")
struct PendingPairingTests {
    /// Generating a code created a Devices entry straight away, so both Macs showed a paired
    /// device before anything had happened — and entering a code then added a second. A
    /// pairing is not a paired Mac until a connection has succeeded.
    @Test("an unused pairing is not a paired Mac")
    func unusedIsNotPaired() {
        let fresh = Pairing(psk: Crypto.randomBytes(32), label: "Mac 1")
        #expect(!fresh.isBound)

        var connected = fresh
        connected.peerDeviceID = DeviceID()
        connected.peerName = "NAV-LT-0416"
        #expect(connected.isBound)
    }

    /// Two outstanding codes means two keys, and no way to tell which one the other Mac was
    /// given — which is how a second "Mac 2" appeared for a single other machine.
    @Test("a new code replaces an unused one rather than adding to it")
    func replacesUnused() {
        var store = SecretStore()
        store.pairings = [Pairing(psk: Crypto.randomBytes(32), label: "Mac 1")]

        store.pairings.removeAll { !$0.isBound }
        store.pairings.append(Pairing(psk: Crypto.randomBytes(32), label: "Mac 1"))
        #expect(store.pairings.count == 1)
    }

    @Test("a Mac that has connected is never discarded by that rule")
    func keepsBoundPairings() {
        var bound = Pairing(psk: Crypto.randomBytes(32), label: "Work Mac")
        bound.peerDeviceID = DeviceID()
        bound.peerName = "NAV-LT-0416"

        var store = SecretStore()
        store.pairings = [bound, Pairing(psk: Crypto.randomBytes(32), label: "Mac 2")]
        store.pairings.removeAll { !$0.isBound }

        #expect(store.pairings.count == 1)
        #expect(store.pairings[0].peerName == "NAV-LT-0416")
    }
}

@Suite("Link preference")
struct LinkPreferenceTests {
    private func peer(addresses: [String], port: UInt16?) -> DiscoveredPeer {
        DiscoveredPeer(serviceName: "Work Mac", deviceID: DeviceID(), role: "client",
                       endpoint: .hostPort(host: NWEndpoint.Host("work.local"), port: 52777),
                       advertisedAddresses: addresses, advertisedPort: port)
    }

    /// A cable gets a self-assigned address and no route, so it cannot be chosen by interface
    /// — only by address.
    @Test("a cable address is recognised and preferred")
    func prefersCable() {
        let found = peer(addresses: ["192.168.1.8", "169.254.251.10"], port: 52777)
        #expect(found.cableAddress == "169.254.251.10")

        for preference in [LinkPreference.cable, .auto] {
            guard case let .hostPort(host, port)? = found.endpoint(preferring: preference) else {
                Issue.record("\(preference) did not pick the cable"); continue
            }
            #expect("\(host)" == "169.254.251.10")
            #expect(port.rawValue == 52777)
        }
    }

    @Test("wi-fi is not diverted onto the cable")
    func wifiKeepsItsEndpoint() {
        let found = peer(addresses: ["192.168.1.8", "169.254.251.10"], port: 52777)
        #expect(found.endpoint(preferring: .wifi) == found.endpoint)
    }

    /// Insisting on a cable that is not there should say so rather than quietly using Wi-Fi.
    @Test("requiring a cable refuses when there is none")
    func cableRequiredButAbsent() {
        let found = peer(addresses: ["192.168.1.8"], port: 52777)
        #expect(found.cableAddress == nil)
        #expect(found.endpoint(preferring: .cable) == nil)
        #expect(found.endpoint(preferring: .auto) == found.endpoint)
    }

    @Test("an advert with no port falls back rather than guessing one")
    func missingPort() {
        let found = peer(addresses: ["169.254.251.10"], port: nil)
        #expect(found.endpoint(preferring: .auto) == found.endpoint)
    }

    /// Only Wi-Fi can be expressed as an interface requirement; requiring wired would match
    /// nothing, because the cable's interface is in no path.
    @Test("only wi-fi maps to an interface requirement")
    func interfaceMapping() {
        #expect(LinkPreference.wifi.interfaceType == .wifi)
        #expect(LinkPreference.cable.interfaceType == nil)
        #expect(LinkPreference.auto.interfaceType == nil)
    }
}

@Suite("Send coalescing")
struct SendCoalescingTests {
    /// Pointer moves carry an absolute position, so only the newest one is true. The reason
    /// this matters is not bandwidth: a queue of stale positions sits in front of whatever
    /// comes next, so the message saying the pointer has left waits behind positions it has
    /// already passed through — seconds of stale cursor on the screen you just left.
    @Test("only the newest position is worth keeping")
    func newestWins() {
        let first = Message.mouseMove(x: 10, y: 10, dx: 1, dy: 1)
        let latest = Message.mouseMove(x: 900, y: 400, dx: 4, dy: 2)

        // Replacing rather than appending must not change what the far end is told.
        guard case let .mouseMove(x, y, _, _) = latest else { Issue.record("wrong case"); return }
        #expect(x == 900 && y == 400)
        #expect(Codec.encodeFrame(first) != Codec.encodeFrame(latest))
    }

    /// Everything that is not a position must go out whole: a dropped click or keystroke is
    /// not recoverable from the next one, the way a dropped position is.
    @Test("only pointer moves are safe to drop")
    func onlyMovesAreDroppable() {
        func isDroppable(_ message: Message) -> Bool {
            if case .mouseMove = message { return true }
            return false
        }
        #expect(isDroppable(.mouseMove(x: 0, y: 0, dx: 0, dy: 0)))
        for message: Message in [
            .mouseButton(button: .left, down: true, clickCount: 1, x: 0, y: 0),
            .keyEvent(keyCode: 8, down: true, isRepeat: false, flags: 0),
            .flagsChanged(flags: 0),
            .scroll(dx: 0, dy: -3, isPixel: true),
            .leaveScreen,
            .enterScreen(x: 0, y: 0, flags: 0),
            .clipboard(kind: "x", payload: Data()),
        ] {
            #expect(!isDroppable(message), "\(message.type) must never be dropped")
        }
    }
}
