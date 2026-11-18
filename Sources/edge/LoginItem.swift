import AppKit
import Foundation
import ServiceManagement
import EdgeCore

/// "Start at login", as the menu means it: Edge.app under Open at Login.
///
/// This used to be a LaunchAgent plist that ran a headless session at login. Two things made
/// it impossible to turn off reliably. System Settings lists such an agent only as an "Allow in
/// the Background" switch — there is no Edge.app to select and remove — and that switch only
/// stops it running, so the plist stayed, the menu still read it as on, and the menu and the
/// system disagreed. Separately, macOS relaunches whatever was running at logout, so Edge
/// came back at login whatever the switch said.
///
/// The main-app login item fixes the first: the system owns the registration, reports its
/// real state, and lists Edge.app where it can be removed with "−". `disableRelaunchOnLogin`
/// fixes the second. And because the menu reads the system's answer rather than a file of its
/// own, removing Edge in System Settings un-ticks the menu too.
enum LoginItem {
    private static var service: SMAppService { .mainApp }

    /// A bare binary has no bundle for the system to register; only the app can do this.
    static var isAvailable: Bool { Permissions.isRunningInsideAppBundle }

    /// On if anything will start Edge at login — including an agent from an older build or
    /// from `edge service install`, because a tick that hides one of those is the bug this
    /// type exists to fix.
    static var isEnabled: Bool {
        (isAvailable && service.status == .enabled) || LaunchAgent.installedRole != nil
    }

    /// Registered, but the person switched it off in System Settings and has to switch it
    /// back on there; an app cannot overrule that.
    static var needsApproval: Bool {
        isAvailable && service.status == .requiresApproval
    }

    enum Outcome {
        case done
        /// The system wants the person to finish this in System Settings.
        case finishInSettings(String)
    }

    static func enable() -> Outcome {
        guard isAvailable else {
            return .finishInSettings("Start at login needs Edge.app, not the bare edge binary.")
        }
        do {
            try service.register()
        } catch {
            Log.warn("could not register the login item: \(error.localizedDescription)")
        }
        switch service.status {
        case .enabled:
            // The agent would start a second session alongside the one the app now starts.
            LaunchAgent.removePlists()
            return .done
        case .requiresApproval:
            return .finishInSettings(
                "Turn Edge on in Login Items, now open in System Settings.")
        default:
            return .finishInSettings(
                "Click + under Open at Login and choose Edge.app.")
        }
    }

    static func disable() -> Outcome {
        if isAvailable, service.status != .notRegistered && service.status != .notFound {
            do {
                try service.unregister()
            } catch {
                Log.warn("could not unregister the login item: \(error.localizedDescription)")
            }
        }
        // Without booting it out: a session the old agent started may be the one running now,
        // and turning off *start at login* is not asking for the link to drop. With its file
        // gone launchd will not load it at the next login, which is the whole of the request.
        LaunchAgent.removePlists()

        // Check rather than assume. A tick that does not match what happens at the next login
        // is the one kind of wrong this switch can be, and it stays invisible until then.
        if isEnabled {
            return .finishInSettings(
                "Select Edge under Open at Login and click −.")
        }
        return .done
    }

    /// Moves an agent left by an older build over to the login item, once, quietly.
    ///
    /// Only when it can actually take over: if the system will not register Edge, the old
    /// agent is left exactly as it was rather than turning start-at-login off by surprise.
    static func migrateFromLaunchAgent() {
        guard isAvailable, LaunchAgent.installedRole != nil else { return }
        if service.status != .enabled { try? service.register() }
        guard service.status == .enabled else { return }
        LaunchAgent.removePlists()
        Log.info("start at login moved from a launch agent to the Edge.app login item")
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
