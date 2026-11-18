import Foundation

/// All on-disk state lives under one directory that the user can inspect, back up, or delete.
public enum Paths {
    public static let appName = "Edge"

    /// Environment override for the state directory.
    ///
    /// Useful for keeping work and personal state apart on one Mac, for running two instances
    /// side by side while testing, and for anyone who would rather their keys lived on an
    /// encrypted volume of their own choosing.
    public static let overrideVariable = "EDGE_HOME"

    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[overrideVariable],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        // Reading this is what triggers the one-time move from the old name, so it happens
        // before the first `load` rather than before the first `save`. A `static let` runs
        // exactly once per process and is thread-safe.
        _ = adoption
        return defaultDirectory
    }

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    public static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    public static var secretsFile: URL { supportDirectory.appendingPathComponent("secrets.json") }
    public static var identityFile: URL { supportDirectory.appendingPathComponent("identity.json") }

    /// Where state lived before this app was called Edge.
    private static let formerAppName = "Continuous"

    /// Moves state over from the old name, once, if it is still there.
    ///
    /// Renaming the app would otherwise look exactly like a factory reset: the pairing keys,
    /// this Mac's identity and the screen arrangement all live in a directory named after the
    /// app, so a new name means an empty one. Moving rather than copying so there is only
    /// ever one of them, and only when the new directory does not exist yet — a second run
    /// must never overwrite real state with something stale.
    private static let adoption: Void = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let former = base.appendingPathComponent(formerAppName, isDirectory: true)
        let current = defaultDirectory
        guard fm.fileExists(atPath: former.path), !fm.fileExists(atPath: current.path) else { return }
        do {
            try fm.moveItem(at: former, to: current)
            Log.info("moved your pairings and settings over from \(formerAppName)")
        } catch {
            Log.warn("could not move state over from \(formerAppName): \(error.localizedDescription)")
        }
    }()

    /// Creates the support directory with `0700` so that other local users cannot even list it.
    @discardableResult
    public static func ensureSupportDirectory() throws -> URL {
        let dir = supportDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } else {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        return dir
    }
}
