import AppKit
import CoreGraphics

/// Volume, playback, brightness and keyboard-backlight keys.
///
/// These are not key events. macOS delivers them as *system-defined* events (subtype 8,
/// "auxiliary control buttons"), whatever produced them: an Apple keyboard's top row, or the
/// fn layer of a third-party one. An event tap that only asks for key events never sees them,
/// which is why they kept acting on the primary while everything else typed on the secondary.
///
/// Only keys that make sense on whichever Mac you are working on are carried across. Power,
/// eject and the lock keys always stay where they were pressed.
public struct MediaKey: Equatable, Sendable {
    /// `NX_SYSDEFINED`. Not a named `CGEventType` case, so the raw value has to do.
    public static let eventType: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`.
    static let auxControlSubtype: Int16 = 8

    /// `NX_KEYTYPE_*` values, from IOKit's `ev_keymap.h`.
    public static let forwardable: Set<UInt8> = [
        0,   // sound up
        1,   // sound down
        2,   // brightness up
        3,   // brightness down
        7,   // mute
        16,  // play / pause
        17,  // next
        18,  // previous
        19,  // fast-forward
        20,  // rewind
        21,  // keyboard backlight up
        22,  // keyboard backlight down
        23,  // keyboard backlight on / off
    ]

    public var key: UInt8
    public var down: Bool
    public var isRepeat: Bool

    public init(key: UInt8, down: Bool, isRepeat: Bool) {
        self.key = key
        self.down = down
        self.isRepeat = isRepeat
    }

    /// The media key in a system-defined event, or nil if it is not one worth carrying across.
    public init?(_ event: CGEvent) {
        guard event.type.rawValue == Self.eventType,
              let ns = NSEvent(cgEvent: event), ns.type == .systemDefined,
              ns.subtype.rawValue == Self.auxControlSubtype else { return nil }
        self.init(data1: ns.data1)
    }

    /// Decodes the packed field the system uses: key type in the top half, then the key
    /// state (0x0A down, 0x0B up), then a repeat bit.
    public init?(data1: Int) {
        let key = UInt8(truncatingIfNeeded: (data1 >> 16) & 0xFF)
        let state = (data1 >> 8) & 0xFF
        guard Self.forwardable.contains(key), state == 0x0A || state == 0x0B else { return nil }
        self.init(key: key, down: state == 0x0A, isRepeat: data1 & 0x1 != 0)
    }

    public var data1: Int {
        (Int(key) << 16) | ((down ? 0x0A : 0x0B) << 8) | (isRepeat ? 1 : 0)
    }

    /// The event a real keyboard would have produced, ready to post.
    public func makeEvent() -> CGEvent? {
        NSEvent.otherEvent(with: .systemDefined,
                           location: .zero,
                           modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                           timestamp: 0,
                           windowNumber: 0,
                           context: nil,
                           subtype: Self.auxControlSubtype,
                           data1: data1,
                           data2: -1)?.cgEvent
    }
}
