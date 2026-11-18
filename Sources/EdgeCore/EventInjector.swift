import Foundation
import CoreGraphics

/// Synthesises pointer and keyboard events on the Mac that is lending its screen.
///
/// Everything is posted to `.cghidEventTap`, the lowest point in the chain, so the events are
/// indistinguishable from a real device to everything above: the window server, Mission
/// Control, and every application.
///
/// The class is deliberately stateful. Held buttons, the current modifier set and the pressed
/// keys all have to be tracked, because a dropped link in the middle of a drag or with Command
/// held down would otherwise leave this Mac stuck in that state with no device to undo it.
/// See `releaseEverything()`.
public final class EventInjector {
    private let source: CGEventSource?
    private var heldButtons: [MouseButtonID: Bool] = [:]
    private var heldKeys: Set<UInt16> = []
    private var flags: CGEventFlags = []
    private let lock = NSLock()

    public init() {
        source = CGEventSource(stateID: .hidSystemState)
        // A warp or a synthetic move normally suppresses local events for a quarter of a
        // second, which reads as a stutter every time the pointer arrives. We want our events
        // to take effect immediately.
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
    }

    // MARK: - Pointer

    /// Moves the pointer to an absolute position on this Mac.
    ///
    /// Absolute rather than relative on purpose: the sending Mac owns the pointer position for
    /// both machines, so there is exactly one authority and no drift to accumulate.
    public func move(to point: ScreenPoint, delta: ScreenPoint = ScreenPoint(x: 0, y: 0)) {
        lock.lock()
        let dragging = heldButtons.first(where: { $0.value })?.key
        lock.unlock()

        let type: CGEventType
        let button: CGMouseButton
        switch dragging {
        case .some(.left):   type = .leftMouseDragged;  button = .left
        case .some(.right):  type = .rightMouseDragged; button = .right
        case .some(let b):   type = .otherMouseDragged; button = CGMouseButton(rawValue: UInt32(b.rawValue)) ?? .center
        case nil:            type = .mouseMoved;        button = .left
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: CGPoint(x: point.x, y: point.y),
                                  mouseButton: button) else { return }
        // Apps that read raw deltas (games, drawing tools) need these; without them a
        // synthetic move looks like an infinitely fast teleport.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        event.flags = currentFlags
        event.post(tap: .cghidEventTap)
    }

    /// Places the pointer without generating a move event. Used when it first arrives, so the
    /// Mac does not see a single enormous jump from wherever it was left.
    public func warp(to point: ScreenPoint) {
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public func button(_ button: MouseButtonID, down: Bool, clickCount: Int, at point: ScreenPoint) {
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case .left:   type = down ? .leftMouseDown : .leftMouseUp;   cgButton = .left
        case .right:  type = down ? .rightMouseDown : .rightMouseUp; cgButton = .right
        case .middle: type = down ? .otherMouseDown : .otherMouseUp; cgButton = .center
        case .other3, .other4:
            type = down ? .otherMouseDown : .otherMouseUp
            cgButton = CGMouseButton(rawValue: UInt32(button.rawValue)) ?? .center
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: CGPoint(x: point.x, y: point.y),
                                  mouseButton: cgButton) else { return }
        // Without this a double click arrives as two unrelated single clicks.
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        event.flags = currentFlags
        event.post(tap: .cghidEventTap)

        lock.lock(); heldButtons[button] = down; lock.unlock()
    }

    public func scroll(dx: Int32, dy: Int32, isPixel: Bool) {
        guard let event = CGEvent(scrollWheelEvent2Source: source,
                                  units: isPixel ? .pixel : .line,
                                  wheelCount: 2,
                                  wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        event.flags = currentFlags
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    /// Posts a key by *virtual key code*, not by character.
    ///
    /// This is what makes two Macs with different keyboard layouts behave sensibly: the key in
    /// a given physical position produces whatever that position produces on this Mac, exactly
    /// as if you had reached over and pressed it.
    public func key(code: UInt16, down: Bool, isRepeat: Bool, flags rawFlags: UInt64) {
        setFlags(rawFlags)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        else { return }
        event.flags = CGEventFlags(rawValue: rawFlags)
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event.post(tap: .cghidEventTap)

        lock.lock()
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
        lock.unlock()
    }

    /// Volume, playback and brightness, as the keyboard over there would have sent them.
    ///
    /// Not tracked for `releaseEverything`: each press is a self-contained down and up, and
    /// nothing is left half-done if the link drops between the two.
    public func mediaKey(_ key: MediaKey) {
        key.makeEvent()?.post(tap: .cghidEventTap)
    }

    /// Mirrors a modifier change. Some apps watch `flagsChanged` directly rather than reading
    /// the flags off each key event, so the event itself has to exist.
    public func changeFlags(_ rawFlags: UInt64, keyCode: UInt16 = 0) {
        setFlags(rawFlags)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        else { return }
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: rawFlags)
        event.post(tap: .cghidEventTap)
    }

    public func setFlags(_ rawFlags: UInt64) {
        lock.lock(); flags = CGEventFlags(rawValue: rawFlags); lock.unlock()
    }

    private var currentFlags: CGEventFlags {
        lock.lock(); defer { lock.unlock() }
        return flags
    }

    /// Types a string by looking up each character in the current keyboard layout.
    ///
    /// Only used by the self-test. The live path forwards key codes, which is both faster and
    /// correct across layouts.
    public func type(_ text: String, characterDelay: TimeInterval = 0.012) {
        for character in text {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            else { continue }
            var utf16 = Array(String(character).utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.post(tap: .cghidEventTap)

            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: characterDelay)
        }
    }

    // MARK: - Safety

    /// Lets go of everything this Mac is currently holding down.
    ///
    /// Called whenever the link drops. Without it, a connection lost mid-drag leaves a button
    /// stuck down, and one lost while Command is held leaves every subsequent keystroke being
    /// read as a shortcut — on a Mac whose keyboard is in another room.
    public func releaseEverything() {
        lock.lock()
        let buttons = heldButtons.filter { $0.value }.map(\.key)
        let keys = heldKeys
        heldButtons.removeAll()
        heldKeys.removeAll()
        flags = []
        lock.unlock()

        let at = Displays.pointerLocation
        for b in buttons { button(b, down: false, clickCount: 1, at: at) }
        for code in keys { key(code: code, down: false, isRepeat: false, flags: 0) }
        if !buttons.isEmpty || !keys.isEmpty {
            Log.info("released \(buttons.count) button(s) and \(keys.count) key(s) left held by the dropped link")
        }
        changeFlags(0)
    }
}
