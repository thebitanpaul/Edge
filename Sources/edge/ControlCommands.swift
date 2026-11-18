import AppKit
import EdgeControlState
import EdgeCore
import Foundation
import WidgetKit

extension Commands {
    /// Checks, step by step, everything Control Center needs to show Edge and reach it.
    ///
    /// Each step is something that has gone wrong silently somewhere: a control that never
    /// appears in the gallery looks the same whether the extension is missing, unsigned,
    /// unregistered or simply on an older macOS.
    static func controls(_ args: Args) throws {
        out(Style.bold("Control Center"))

        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) else {
            bad("the Edge switch in Control Center needs macOS 26 or later")
            return
        }
        ok("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        guard Permissions.isRunningInsideAppBundle,
              let appex = Bundle.main.builtInPlugInsURL?
                .appendingPathComponent("EdgeControls.appex"),
              FileManager.default.fileExists(atPath: appex.path) else {
            bad("this copy of Edge has no controls built in — run Scripts/build.sh")
            return
        }
        ok("extension  \(appex.path)")

        // Without this, Control Center shows the switch but a tap does nothing at all: it
        // cannot turn the intent into an action ("action intent without linkAction").
        let metadata = appex.appendingPathComponent(
            "Contents/Resources/Metadata.appintents/extract.actionsdata")
        if let data = try? Data(contentsOf: metadata),
           let text = String(data: data, encoding: .utf8),
           text.contains("EdgeControls.PowerIntent"), text.contains("EdgeControls.OptionsIntent"),
           !text.contains("_INTENT_TYPE__") {
            ok("the controls' actions are described to macOS")
        } else {
            bad("the switch's action metadata is missing — taps would do nothing; rebuild with Scripts/build.sh")
        }

        let entitlements = shell("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", appex.path])
        if entitlements.contains("com.apple.security.app-sandbox") {
            ok("extension is sandboxed, as macOS requires")
        } else {
            bad("extension is not sandboxed — macOS will not load it; rebuild with Scripts/build.sh")
        }

        let registered = shell("/usr/bin/pluginkit", ["-m", "-v", "-i", ControlState.extensionBundleID])
            .split(separator: "\n").map(String.init)
            .filter { $0.contains(ControlState.extensionBundleID) }   // not the "(1 plug-in)" summary
        let here = appex.resolvingSymlinksInPath().path
        if registered.isEmpty {
            bad("macOS has not registered the extension — open Edge.app once, then check again")
        } else if registered.contains(where: { $0.contains(here) }) {
            ok("registered with macOS")
            if registered.count > 1 {
                warn("\(registered.count - 1) other copy of Edge is registered too; macOS may use either:")
                for line in registered where !line.contains(here) { out(Style.dim("    \(line)")) }
            }
        } else {
            warn("macOS has a different copy of Edge registered for its controls:")
            for line in registered { out(Style.dim("    \(line)")) }
        }

        // The one failure nothing else here can see: macOS loads the extension, it dies, and
        // Control Center simply leaves Edge out of its gallery. The crash reports are the trace.
        let crashes = crashReports(since: modificationDate(of: appex
            .appendingPathComponent("Contents/MacOS/EdgeControls")))
        if crashes.isEmpty {
            ok("no extension crashes since this build")
        } else {
            bad("the extension has crashed \(crashes.count) time(s) since this build — Control Center "
                + "will not list it. Latest report:")
            out(Style.dim("    \(crashes[0].path)"))
        }

        if let handler = NSWorkspace.shared.urlForApplication(toOpen: ControlState.startURL) {
            if handler.resolvingSymlinksInPath().path == Bundle.main.bundleURL.resolvingSymlinksInPath().path {
                ok("taps on the switch open this copy of Edge")
            } else {
                warn("taps on the switch open a different copy: \(handler.path)")
            }
        } else {
            bad("nothing handles edge-control:// links — open Edge.app once, then check again")
        }

        if #available(macOS 26.0, *) {
            let placed = placedControlKinds()
            switch placed {
            case .none:
                warn("could not ask Control Center which controls are placed")
            case .some(let kinds):
                if args.has("verbose") {
                    out(Style.dim("    placed: \(kinds.isEmpty ? "nothing" : kinds.sorted().joined(separator: ", "))"))
                }
                let power = kinds.contains(ControlState.powerKind)
                let options = kinds.contains(ControlState.optionsKind)
                (power ? ok : info)("the Edge switch \(power ? "is" : "is not") in Control Center")
                (options ? ok : info)("Edge Options \(options ? "is" : "is not") in Control Center (optional)")
                if !power && !options {
                    out(Style.dim("    Edit Controls, search for Edge. The menu-bar icon can only be hidden once one is there."))
                }
            }
        }

        // Where macOS put them is not something it tells the app; the menu bar can be read.
        let extras = MenuBarExtras.systemItems()
        if extras.isEmpty {
            info("could not read the menu bar (Accessibility) — a duplicate icon cannot be avoided")
        } else if extras.contains(where: \.isEdgeControl) {
            ok("an Edge control is in the menu bar — Edge's own icon stands aside for it")
        } else {
            info("no Edge control in the menu bar")
        }
        if args.has("verbose") {
            for item in extras {
                out(Style.dim("    menu bar: \(item.identifier.isEmpty ? "—" : item.identifier)  \(item.description)\(item.title.isEmpty ? "" : "  [\(item.title)]")"))
            }
        }

        if let state = ControlState.read() {
            info("the control shows: Edge · \(state.subtitle)")
        } else {
            info("the control has nothing to show yet — it reads Off until Edge.app has run")
        }
    }

    @available(macOS 26.0, *)
    private static func placedControlKinds() -> Set<String>? {
        let result = Box<Set<String>?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task {
            result.value = try? Set(await ControlCenter.shared.currentControls().map(\.kind))
            done.signal()
        }
        return done.wait(timeout: .now() + 5) == .success ? result.value : nil
    }

    private static func modificationDate(of url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
            ?? .distantPast
    }

    /// The extension's crash reports newer than `date`, newest first.
    private static func crashReports(since date: Date) -> [URL] {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        let reports = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return reports
            .filter { $0.lastPathComponent.hasPrefix("EdgeControls") && modificationDate(of: $0) > date }
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
    }

    private static func shell(_ path: String, _ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        guard (try? task.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
