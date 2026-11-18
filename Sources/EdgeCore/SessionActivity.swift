import Foundation

/// What a session asks of the power system, scoped to whether a link is up.
///
/// Always: opt out of App Nap. A session started by the menu-bar app is a background process,
/// and App Nap throttling it shows up as a laggy pointer on the other Mac.
///
/// Only while linked: latency-critical, which also stops the system coalescing this process's
/// timers — worth it while input is flowing, pure cost while nothing is connected. And, when
/// asked, keeping the system awake: the secondary gets no input of its own while you work on
/// the primary, so without it, it would idle-sleep mid-session and vanish from under the
/// pointer. Neither is held with no link, so a Mac running Edge on its own still sleeps.
public final class SessionActivity {
    private let reason: String
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    private var options: ProcessInfo.ActivityOptions?

    public init(reason: String) {
        self.reason = reason
    }

    public func update(linked: Bool, keepAwake: Bool = false) {
        var wanted: ProcessInfo.ActivityOptions = [.userInitiatedAllowingIdleSystemSleep]
        if linked {
            wanted.insert(.latencyCritical)
            if keepAwake { wanted.insert(.idleSystemSleepDisabled) }
        }
        lock.lock(); defer { lock.unlock() }
        guard wanted != options else { return }
        // The new one first, so there is never a moment with neither.
        let next = ProcessInfo.processInfo.beginActivity(options: wanted, reason: reason)
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = next
        options = wanted
    }

    public func end() {
        lock.lock(); defer { lock.unlock() }
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
        options = nil
    }

    deinit { end() }
}
