import AppKit

/// Asks for one line of text, in a window this code owns.
///
/// `NSAlert` with an accessory text field does not work from a menu-bar app: the alert is
/// opened while AppKit is still tracking the menu, so its window never becomes key, and a
/// field that is never first responder silently ignores every keystroke. It looks like a
/// broken text field rather than an inactive window, which is a bad thing to ship twice.
///
/// Owning the window means the first responder can simply be set, after the window is on
/// screen, with no ordering to get wrong.
enum InputPanel {
    @discardableResult
    static func ask(title: String,
                    explanation: String,
                    value: String = "",
                    placeholder: String = "",
                    confirm: String = "OK") -> String? {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 158),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        guard let content = window.contentView else { return nil }

        let heading = NSTextField(labelWithString: title)
        heading.frame = NSRect(x: 20, y: 118, width: 360, height: 22)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        content.addSubview(heading)

        let subtitle = NSTextField(wrappingLabelWithString: explanation)
        subtitle.frame = NSRect(x: 20, y: 76, width: 360, height: 38)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        content.addSubview(subtitle)

        let field = NSTextField(frame: NSRect(x: 20, y: 46, width: 360, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        content.addSubview(field)

        let ok = NSButton(frame: NSRect(x: 290, y: 12, width: 90, height: 28))
        ok.title = confirm
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        content.addSubview(ok)

        let cancel = NSButton(frame: NSRect(x: 192, y: 12, width: 90, height: 28))
        cancel.title = "Cancel"
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)

        let responder = ButtonTarget()
        ok.target = responder
        ok.action = #selector(ButtonTarget.accept)
        cancel.target = responder
        cancel.action = #selector(ButtonTarget.reject)

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        // After the window is on screen, not before: a field made first responder on a window
        // that is not yet key does not keep it.
        window.makeFirstResponder(field)

        let outcome = NSApp.runModal(for: window)
        window.orderOut(nil)
        guard outcome == .OK else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `NSApp.runModal` needs a target that outlives the call.
    private final class ButtonTarget: NSObject {
        @objc func accept() { NSApp.stopModal(withCode: .OK) }
        @objc func reject() { NSApp.stopModal(withCode: .cancel) }
    }
}
