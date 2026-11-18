import Foundation
import ApplicationServices
import IOKit.hid

/// macOS privacy gates that this tool depends on.
///
/// Both are deliberately hard to get: they are exactly the permissions that make a
/// keyboard-sharing tool possible, and exactly the ones you would not want to hand to a
/// closed-source app. Here the code asking for them is the code in this repository.
public enum Permissions {
    public enum Status: Sendable, CustomStringConvertible {
        case granted
        case denied
        case undetermined
        case unknown

        public var description: String {
            switch self {
            case .granted: return "granted"
            case .denied: return "denied"
            case .undetermined: return "not yet asked"
            case .unknown: return "unknown"
            }
        }

        public var isGranted: Bool { self == .granted }
    }

    /// Needed to *post* synthesized events into other apps (client side) and to consume
    /// events in an event tap (host side).
    public static func accessibility(prompt: Bool = false) -> Status {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
    }

    /// Needed to *read* keyboard events in a CGEventTap (host side).
    public static func inputMonitoring() -> Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        case kIOHIDAccessTypeUnknown: return .undetermined
        default: return .unknown
        }
    }

    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public static let accessibilitySettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    public static let inputMonitoringSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

    public static func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [url.absoluteString]
        try? task.run()
    }

    /// True when the running binary lives inside a `.app`, which is what makes macOS attribute
    /// the privacy grants to Edge rather than to whatever terminal launched it.
    public static var isRunningInsideAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundlePath.hasSuffix(".app")
    }
}
