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
