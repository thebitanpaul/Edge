import Testing
import Foundation
import AppKit
@testable import ContinuousCore

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
        let board = try #require(NSPasteboard(name: .init("app.continuous.tests.\(UUID().uuidString)")))
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
        let board = try #require(NSPasteboard(name: .init("app.continuous.tests.\(UUID().uuidString)")))
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
        let data = try JSONEncoder.continuousJSON.encode(store)
        let back = try JSONDecoder.continuousJSON.decode(SecretStore.self, from: data)
        #expect(back.pairings[0].manualEndpoint == "192.168.1.42:52777")
    }
}
