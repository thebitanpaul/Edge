import AppKit
import ApplicationServices
import EdgeControlState

/// Whether one of Edge's Control Center controls has been put in the menu bar.
///
/// macOS offers "Add to Menu Bar" for every control and gives the app no say in it and no way to
/// find out — there is no WidgetKit API for where a control was placed. The menu bar itself is
/// readable, though: the system items, controls included, are hosted by a system process whose
/// menu-bar extras Accessibility can list, each with an identifier and a description. Edge
/// already holds Accessibility, so it can look.
///
/// Matched loosely on purpose, by identifier or by name, since neither format is documented.
/// A miss only means Edge's own icon stays visible alongside — the state it was in anyway.
enum MenuBarExtras {
    /// System processes that host menu-bar extras. Asked in turn; whichever has them answers.
    private static let hosts = ["com.apple.MenuBarAgent", "com.apple.controlcenter",
                                "com.apple.systemuiserver"]

    struct Item {
        let identifier: String
        let description: String
        let title: String

        var isEdgeControl: Bool {
            if identifier.contains(ControlState.extensionBundleID) { return true }
            // The control's display name is "Edge"; Accessibility tends to add the state
            // after a comma, the way Wi-Fi reads "Wi-Fi, connected".
            return [description, title].contains { name in
                name == "Edge" || name.hasPrefix("Edge,") || name.hasPrefix("Edge Options")
            }
        }
    }

    /// Every menu-bar extra the system hosts. Blocking; call off the main thread.
    static func systemItems() -> [Item] {
        guard AXIsProcessTrusted() else { return [] }
        var items: [Item] = []
        for bundleID in hosts {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                // A hung system process must not hang this app with it.
                AXUIElementSetMessagingTimeout(element, 0.5)
                guard let bar = value(element, "AXExtrasMenuBar") else { continue }
                collect(bar as! AXUIElement, depth: 0, into: &items)
            }
        }
        return items
    }

    static func edgeControlInMenuBar() -> Bool {
        systemItems().contains(where: \.isEdgeControl)
    }

    private static func collect(_ element: AXUIElement, depth: Int, into items: inout [Item]) {
        if (value(element, kAXRoleAttribute) as? String) == (kAXMenuBarItemRole as String) {
            items.append(Item(identifier: value(element, kAXIdentifierAttribute) as? String ?? "",
                              description: value(element, kAXDescriptionAttribute) as? String ?? "",
                              title: value(element, kAXTitleAttribute) as? String ?? ""))
            return
        }
        guard depth < 3 else { return }
        for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            collect(child, depth: depth + 1, into: &items)
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success
        else { return nil }
        return result
    }
}
