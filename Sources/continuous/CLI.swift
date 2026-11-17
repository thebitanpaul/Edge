import Foundation
import ContinuousCore

// MARK: - Terminal styling

enum Style {
    static let enabled = isatty(STDOUT_FILENO) == 1

    static func wrap(_ s: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }

    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func green(_ s: String) -> String { wrap(s, "0;32") }
    static func yellow(_ s: String) -> String { wrap(s, "0;33") }
    static func red(_ s: String) -> String { wrap(s, "0;31") }
    static func cyan(_ s: String) -> String { wrap(s, "0;36") }
}

func out(_ s: String = "") { print(s) }
func ok(_ s: String)   { print("\(Style.green("✓")) \(s)") }
func warn(_ s: String) { print("\(Style.yellow("!")) \(s)") }
func bad(_ s: String)  { print("\(Style.red("✗")) \(s)") }
func info(_ s: String) { print("\(Style.cyan("·")) \(s)") }

// MARK: - Argument parsing

struct Args {
    private(set) var positional: [String] = []
    private(set) var flags: [String: String] = [:]

    /// Flags that take no value, so `--no-bonjour listen` is not misread.
    static let booleanFlags: Set<String> = [
        "help", "version", "no-bonjour", "allow-public", "rebind",
        "json", "quiet", "prompt", "no-prompt", "force", "once", "keys", "link-only",
        "no-retry", "open",
    ]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" {
                positional.append(contentsOf: argv[(i + 1)...])
                break
            }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    flags[String(body[body.startIndex..<eq])] = String(body[body.index(after: eq)...])
                } else if Self.booleanFlags.contains(body) {
                    flags[body] = "true"
                } else if i + 1 < argv.count && !argv[i + 1].hasPrefix("--") {
                    flags[body] = argv[i + 1]
                    i += 1
                } else {
                    flags[body] = "true"
                }
            } else if a == "-h" {
                flags["help"] = "true"
            } else if a == "-v" {
                flags["version"] = "true"
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func has(_ name: String) -> Bool { flags[name] != nil }
    func string(_ name: String) -> String? { flags[name] }

    func bool(_ name: String, default def: Bool = false) -> Bool {
        guard let v = flags[name] else { return def }
        return ["true", "yes", "1", "on"].contains(v.lowercased())
    }

    func uint16(_ name: String) throws -> UInt16? {
        guard let v = flags[name] else { return nil }
        guard let n = UInt16(v) else {
            throw ContinuousError.invalidArgument("--\(name) expects a port number, got '\(v)'")
        }
        return n
    }

    func double(_ name: String) throws -> Double? {
        guard let v = flags[name] else { return nil }
        guard let n = Double(v) else {
            throw ContinuousError.invalidArgument("--\(name) expects a number, got '\(v)'")
        }
        return n
    }

    func arg(_ i: Int) -> String? { i < positional.count ? positional[i] : nil }

    func require(_ i: Int, _ name: String) throws -> String {
        guard let v = arg(i) else {
            throw ContinuousError.invalidArgument("missing required argument <\(name)>")
        }
        return v
    }
}

// MARK: - Shared helpers

enum Runtime {
    static let version: String = {
        let base = "0.2.0"
        guard let info = Bundle.main.infoDictionary,
              let commit = info["ContinuousCommit"] as? String else {
            return base + " (unstamped build — run Scripts/build.sh)"
        }
        let built = (info["ContinuousBuiltAt"] as? String).map { ", built \($0)" } ?? ""
        return "\(base) (commit \(commit)\(built))"
    }()

    /// Waits for `condition`, servicing the run loop while it waits.
    ///
    /// It used to sleep instead, which looks equivalent and is not: anything delivered via
    /// `DispatchQueue.main.async` — which is how work gets back to the main thread from a
    /// network callback — never runs while the main thread is asleep. A caller waiting on a
    /// result that arrives that way waits for ever and then reports a timeout, with the
    /// answer sitting undelivered in the queue the whole time.
    static func wait(until condition: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    nonisolated(unsafe) static var interrupted = false

    /// Spins the main run loop while `shouldContinue` holds.
    ///
    /// Not the same as sleeping in a loop: CoreGraphics delivers display-reconfiguration
    /// callbacks — and event taps — through the run loop, so a plain sleep would silently
    /// never see a monitor being plugged in.
    ///
    /// Takes a predicate rather than reading `interrupted` directly, because "this connection
    /// ended" and "the user pressed Ctrl-C" are different things: conflating them means a
    /// dropped link looks like a request to quit, and nothing ever reconnects.
    static func run(while shouldContinue: () -> Bool, onTick: (() -> Void)? = nil) {
        while shouldContinue() {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            onTick?()
        }
    }

    static func runUntilInterrupted(onTick: (() -> Void)? = nil) {
        run(while: { !interrupted }, onTick: onTick)
    }

    static func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let int = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        for src in [int, term] {
            src.setEventHandler { interrupted = true }
            src.resume()
        }
        // Keep the sources alive for the process lifetime.
        sources = [int, term]
    }

    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
}

func relativeTime(_ date: Date?) -> String {
    guard let date else { return "never" }
    let seconds = Int(Date().timeIntervalSince(date))
    switch seconds {
    case ..<60: return "\(max(seconds, 0))s ago"
    case ..<3600: return "\(seconds / 60)m ago"
    case ..<86400: return "\(seconds / 3600)h ago"
    default: return "\(seconds / 86400)d ago"
    }
}
