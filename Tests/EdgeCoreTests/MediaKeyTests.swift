import CoreGraphics
import Foundation
import Testing
@testable import EdgeCore

@Suite("Media keys")
struct MediaKeyTests {
    @Test("the packed field round-trips for every key carried across")
    func roundTrip() {
        for key in MediaKey.forwardable {
            for down in [true, false] {
                for isRepeat in [true, false] {
                    let original = MediaKey(key: key, down: down, isRepeat: isRepeat)
                    #expect(MediaKey(data1: original.data1) == original)
                }
            }
        }
    }

    @Test("volume up decodes as the system packs it")
    func knownLayout() {
        // NX_KEYTYPE_SOUND_UP, key down, not a repeat: what a keyboard sends.
        #expect(MediaKey(data1: 0x0000_0A00) == MediaKey(key: 0, down: true, isRepeat: false))
        // Play/pause released, auto-repeating.
        #expect(MediaKey(data1: 0x0010_0B01) == MediaKey(key: 16, down: false, isRepeat: true))
    }

    @Test("power, eject and the lock keys stay on the Mac they were pressed on")
    func notForwarded() {
        for key: UInt8 in [4, 6, 10, 14] {   // caps lock, power, num lock, eject
            #expect(MediaKey(data1: Int(key) << 16 | 0x0A00) == nil, "key \(key)")
        }
    }

    @Test("an unknown key state is not guessed at")
    func badState() {
        #expect(MediaKey(data1: 0x0000_0C00) == nil)
    }

    @Test("a posted event carries the same key back out")
    func makeEvent() throws {
        let key = MediaKey(key: 7, down: true, isRepeat: false)
        let event = try #require(key.makeEvent())
        #expect(event.type.rawValue == MediaKey.eventType)
        #expect(MediaKey(event) == key)
    }

    @Test("ordinary key events are not mistaken for media keys")
    func ordinaryKeys() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true))
        #expect(MediaKey(event) == nil)
    }

    @Test("the tap asks for system-defined events")
    func tapMask() {
        #expect(EventTap.defaultMask & (CGEventMask(1) << CGEventMask(MediaKey.eventType)) != 0)
    }

    @Test("new builds advertise media keys, so older ones are never sent them")
    func capability() {
        #expect(Capabilities.baseline.contains(.mediaKeys))
        #expect(!Capabilities([.pointer, .keyboard, .scroll]).contains(.mediaKeys))
    }
}

@Suite("Swapping roles")
struct RoleSwitchTests {
    @Test("the other Mac sits on the mirrored edge")
    func mirrored() {
        #expect(ScreenEdge.right.opposite == .left)
        #expect(ScreenEdge.left.opposite == .right)
        #expect(ScreenEdge.top.opposite == .bottom)
        #expect(ScreenEdge.bottom.opposite == .top)
        for edge in ScreenEdge.allCases { #expect(edge.opposite.opposite == edge) }
    }

    @Test("the hand-over carries the arrangement intact")
    func handOverRoundTrip() throws {
        let frame = Codec.encodeFrame(.switchRoles(edge: "bottom", alignment: "center"))
        guard case let .switchRoles(edge, alignment) =
                try Codec.decode(type: frame[4], payload: frame.dropFirst(5)) else {
            Issue.record("decoded the wrong case"); return
        }
        #expect(edge == "bottom")
        #expect(alignment == "center")
    }

    @Test("new builds advertise role switching and forgetting, so older ones are never asked")
    func capability() {
        #expect(Capabilities.baseline.contains(.roleSwitch))
        #expect(Capabilities.baseline.contains(.forgetPairing))
    }

    @Test("a state file from an older build, without the pairing fields, still loads")
    func olderStateLoads() throws {
        var state = RuntimeState(role: .sharing, peerName: "Work Mac")
        state.connected = true
        var object = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder.edgeJSON.encode(state)) as? [String: Any])
        object.removeValue(forKey: "pairingKeyID")
        object.removeValue(forKey: "peerCapabilities")
        let old = try JSONSerialization.data(withJSONObject: object)
        let loaded = try JSONDecoder.edgeJSON.decode(RuntimeState.self, from: old)
        #expect(loaded.connected)
        #expect(loaded.pairingKeyID == nil)
    }

    @Test("a note survives the trip from session to app")
    func noteCodable() throws {
        let note = RoleSwitchNote(becomePrimary: true, edge: "left", alignment: "start",
                                  otherMacFollows: true)
        let data = try JSONEncoder.edgeJSON.encode(note)
        let back = try JSONDecoder.edgeJSON.decode(RoleSwitchNote.self, from: data)
        #expect(back.becomePrimary && back.otherMacFollows)
        #expect(back.edge == "left" && back.alignment == "start")
    }
}
