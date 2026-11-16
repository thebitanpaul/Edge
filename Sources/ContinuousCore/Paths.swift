import Foundation

/// All on-disk state lives under one directory that the user can inspect, back up, or delete.
public enum Paths {
    public static let appName = "Continuous"

    /// Environment override for the state directory.
    ///
    /// Useful for keeping work and personal state apart on one Mac, for running two instances
    /// side by side while testing, and for anyone who would rather their keys lived on an
    /// encrypted volume of their own choosing.
    public static let overrideVariable = "CONTINUOUS_HOME"

    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[overrideVariable],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    public static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    public static var secretsFile: URL { supportDirectory.appendingPathComponent("secrets.json") }
    public static var identityFile: URL { supportDirectory.appendingPathComponent("identity.json") }

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
