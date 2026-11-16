import Foundation

/// Minimal leveled logger. Writes to stderr so that machine-readable command output
/// on stdout stays clean and pipeable.
public enum LogLevel: Int, Comparable, Sendable {
    case trace = 0, debug, info, warn, error

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info:  return "info "
        case .warn:  return "warn "
        case .error: return "error"
        }
    }

    var color: String {
        switch self {
        case .trace: return "\u{1B}[2;37m"
        case .debug: return "\u{1B}[0;36m"
        case .info:  return "\u{1B}[0;32m"
        case .warn:  return "\u{1B}[0;33m"
        case .error: return "\u{1B}[0;31m"
        }
    }

    public static func parse(_ s: String) -> LogLevel? {
        switch s.lowercased() {
        case "trace": return .trace
        case "debug": return .debug
        case "info": return .info
        case "warn", "warning": return .warn
        case "error": return .error
        default: return nil
        }
    }
}

public enum Log {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _level: LogLevel = .info
    private static let useColor: Bool = isatty(STDERR_FILENO) == 1

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static var level: LogLevel {
        get { lock.lock(); defer { lock.unlock() }; return _level }
        set { lock.lock(); _level = newValue; lock.unlock() }
    }

    public static func trace(_ m: @autoclosure () -> String) { emit(.trace, m()) }
    public static func debug(_ m: @autoclosure () -> String) { emit(.debug, m()) }
    public static func info(_ m: @autoclosure () -> String)  { emit(.info, m()) }
    public static func warn(_ m: @autoclosure () -> String)  { emit(.warn, m()) }
    public static func error(_ m: @autoclosure () -> String) { emit(.error, m()) }

    private static func emit(_ lvl: LogLevel, _ message: String) {
        guard lvl >= level else { return }
        let line: String
        if useColor {
            line = "\u{1B}[2m\(stamp.string(from: Date()))\u{1B}[0m \(lvl.color)\(lvl.label)\u{1B}[0m \(message)\n"
        } else {
            line = "\(stamp.string(from: Date())) \(lvl.label) \(message)\n"
        }
        lock.lock()
        FileHandle.standardError.write(Data(line.utf8))
        lock.unlock()
    }
}
