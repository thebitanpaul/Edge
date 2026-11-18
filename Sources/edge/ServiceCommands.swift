import Foundation
import EdgeCore

extension Commands {

    // MARK: - status

    /// What is running right now, if anything.
    static func status(_ args: Args) throws {
        let states = RuntimeState.all.filter(\.isLive)
        // A session that crashed leaves its file behind; do not report it as running.
        for role in [RuntimeState.Role.sharing, .listening] {
            if let state = RuntimeState.load(role), !state.isLive {
                RuntimeState.clear(role)
                Log.debug("cleared a stale \(role.rawValue) state file from pid \(state.pid)")
            }
        }

        guard !states.isEmpty else {
            info("nothing running on this Mac")
            out()
            out(Style.dim("    edge listen     to lend this Mac's screen"))
            out(Style.dim("    edge connect    to share this Mac's keyboard and mouse"))
            if let agent = LaunchAgent.installedRole {
                out()
                info("a login item is installed (\(agent.rawValue)) but is not running")
                out(Style.dim("    edge service start"))
            }
            return
        }

        for state in states {
            let title: String
            switch (state.role, state.sharingInput) {
            case (.sharing, true):  title = "Sharing this Mac's keyboard and mouse"
            case (.sharing, false): title = "Connected (link only — not capturing input)"
            case (.listening, _):   title = "Lending this Mac's screen"
            }
            out(Style.bold(title))
            out("  pid        \(state.pid)")
            out("  uptime     \(formatDuration(state.uptime))")
            if state.connected {
                ok("connected to \(state.peerName ?? "?")\(state.endpoint.map { "  (\($0))" } ?? "")")
            } else {
                warn("not connected\(state.lastError.map { " — \($0)" } ?? "")")
            }
            if state.role == .sharing, state.sharingInput {
                let pointer = (state.pointerIsRemote ?? false)
                    ? "on \(state.peerName ?? "the other Mac")"
                    : "on this Mac"
                out("  pointer    \(pointer)")
            }
            out()
        }

        if let role = LaunchAgent.installedRole {
            info("starts at login as '\(role.rawValue)'")
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    // MARK: - service

    static func service(_ args: Args) throws {
        switch args.arg(0) ?? "status" {
        case "install":   try serviceInstall(args)
        case "uninstall": try serviceUninstall(args)
        case "start":     try LaunchAgent.start()
        case "stop":      try LaunchAgent.stop()
        case "status":    try serviceStatus(args)
        default:
            throw EdgeError.invalidArgument(
                "unknown `service` subcommand — expected install, uninstall, start, stop or status")
        }
    }

    private static func serviceInstall(_ args: Args) throws {
        guard Permissions.isRunningInsideAppBundle else {
            throw EdgeError.invalidArgument("""
                run this from the app bundle, not the bare binary.
                  A login item launched from a bare binary would hold privacy permissions
                  granted to whatever built it, which is not what you want running every day.
                      Scripts/build.sh
                      build/edge service install
                """)
        }

        let roleText = args.arg(1) ?? args.string("role") ?? "listen"
        let role: RuntimeState.Role
        switch roleText {
        case "listen", "listening", "client": role = .listening
        case "connect", "sharing", "host":    role = .sharing
        default:
            throw EdgeError.invalidArgument("role must be `listen` or `connect`, got '\(roleText)'")
        }

        if role == .sharing {
            warn("installing the sharing side as a login item")
            out(Style.dim("    It will capture this Mac's keyboard and mouse from the moment you log in."))
            out(Style.dim("    The escape chord ⌘ ⌥ ⌃ ⇧ still works, and `edge service stop` ends it."))
        }

        let path = try LaunchAgent.install(role: role, extraArguments: args.string("args")?
            .split(separator: " ").map(String.init) ?? [])
        ok("installed \(path.path)")
        try LaunchAgent.start()
        ok("started — it will come back on every login")
        out()
        out(Style.dim("    edge status            see what it is doing"))
        out(Style.dim("    edge service stop      stop it for now"))
        out(Style.dim("    edge service uninstall remove it"))
    }

    private static func serviceUninstall(_ args: Args) throws {
        guard LaunchAgent.installedRole != nil else {
            info("no login item is installed")
            return
        }
        try LaunchAgent.uninstall()
        ok("removed — Edge will no longer start at login")
    }

    private static func serviceStatus(_ args: Args) throws {
        guard let role = LaunchAgent.installedRole else {
            info("no login item installed")
            out(Style.dim("    edge service install listen     on the Mac lending its screen"))
            out(Style.dim("    edge service install connect    on the Mac with the keyboard"))
            return
        }
        ok("login item installed: \(role.rawValue)")
        out("  plist   \(LaunchAgent.plistURL.path)")
        out("  logs    \(LaunchAgent.logURL.path)")
        if let running = RuntimeState.load(role), running.isLive {
            ok("running as pid \(running.pid)")
        } else {
            warn("not currently running — `edge service start`")
        }
    }
}

/// A user LaunchAgent, so Edge comes back after a reboot without being told to.
///
/// A user agent rather than a system daemon on purpose: it runs as you, in your login session,
/// with your privacy permissions and no root anywhere. There is nothing here that needs more
/// than that, and a keyboard logger running as root is precisely what this project exists to
/// avoid installing.
enum LaunchAgent {
    static let label = "app.edge.agent"
    /// The label this agent had when the app was called Continuous.
    ///
    /// An agent is identified by its label, so renaming the app left the old one installed,
    /// loaded, and pointing at a bundle that no longer exists — invisible to a menu that only
    /// knows the new name. Turning "Start at login" off therefore turned nothing off. It is
    /// looked for everywhere the current one is.
    static let formerLabel = "app.continuous.agent"

    static func plistURL(_ label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var plistURL: URL { plistURL(label) }
    static var formerPlistURL: URL { plistURL(formerLabel) }

    /// Every agent of ours that is installed, old name included.
    static var installedLabels: [String] {
        [label, formerLabel].filter { FileManager.default.fileExists(atPath: plistURL($0).path) }
    }

    static var logURL: URL {
        Paths.supportDirectory.appendingPathComponent("agent.log")
    }

    static var installedRole: RuntimeState.Role? {
        for label in installedLabels {
            guard let data = try? Data(contentsOf: plistURL(label)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  let arguments = plist["ProgramArguments"] as? [String] else { continue }
            if arguments.contains("listen") { return .listening }
            if arguments.contains("connect") { return .sharing }
        }
        return nil
    }

    @discardableResult
    static func install(role: RuntimeState.Role, extraArguments: [String]) throws -> URL {
        let executable = Bundle.main.executableURL?.path
            ?? "/usr/local/bin/edge"
        var arguments = [executable, role == .listening ? "listen" : "connect"]
        arguments.append(contentsOf: extraArguments)

        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Paths.ensureSupportDirectory()

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            // launchd restarts it if it exits, but not faster than this — otherwise a
            // misconfiguration becomes a busy loop that is hard to interrupt.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "EnvironmentVariables": ProcessInfo.processInfo.environment[Paths.overrideVariable]
                .map { [Paths.overrideVariable: $0] } ?? [:],
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        return plistURL
    }

    /// Removes every agent of ours and checks that it worked.
    ///
    /// Deliberately not `try?` on the part that matters. Removing the file silently failing is
    /// how a switch comes to be off in the menu and on at login, which is worse than an error:
    /// nothing in the interface disagrees with itself, so there is nothing to investigate.
    static func uninstall() throws {
        for label in [self.label, formerLabel] {
            _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
            let url = plistURL(label)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw EdgeError.invalidArgument("""
                    could not remove \(url.path)
                      \(error.localizedDescription)
                      Delete that file and Edge will stop starting at login.
                    """)
            }
        }
        guard installedLabels.isEmpty else {
            throw EdgeError.invalidArgument("the login item is still installed")
        }
    }

    static func start() throws {
        // bootstrap/kickstart is the modern spelling; load is the one that works everywhere.
        _ = try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        _ = try? runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }

    static func stop() throws {
        for label in [self.label, formerLabel] {
            _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        }
    }

    /// Clears out an agent left behind by the old name, whatever else is going on.
    ///
    /// Called at launch. It points at a bundle that no longer exists, so every login it fails,
    /// launchd retries it, and the only trace is a log nobody reads.
    static func removeFormerAgent() {
        guard FileManager.default.fileExists(atPath: formerPlistURL.path) else { return }
        _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(formerLabel)"])
        try? FileManager.default.removeItem(at: formerPlistURL)
        Log.info("removed the login item left behind by the old name")
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if task.terminationStatus != 0, !output.isEmpty {
            Log.debug("launchctl \(arguments.joined(separator: " ")): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}
