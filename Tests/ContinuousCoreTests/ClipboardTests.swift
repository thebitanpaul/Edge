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
