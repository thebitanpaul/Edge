import Foundation
import ContinuousCore

let usage = """
\(Style.bold("continuous")) — share one keyboard and mouse between two Macs, privately.

\(Style.bold("USAGE"))
  continuous <command> [options]

\(Style.bold("GETTING STARTED"))
  On the Mac that will \(Style.bold("lend its screen")):
      continuous pair init --label "Personal Mac"
      continuous listen

  On the Mac with the \(Style.bold("keyboard and mouse")):
      continuous pair join <CODE> --label "Work Mac"
      continuous connect <name-or-ip>

\(Style.bold("COMMANDS"))
  doctor                  Environment, permissions, pairings and network report
  id                      Show this Mac's device identity
  selftest                Run the full crypto + transport check over loopback

  pair init               Generate a pairing code on this Mac
  pair join <CODE>        Accept a pairing code from the other Mac
  pair list               Show stored pairings
  pair forget <NAME>      Delete a pairing and stop accepting its key

  listen                  Accept links from a paired Mac
  connect <HOST|NAME>     Dial a listening Mac and hold the link open
  discover                Browse the local network for listening Macs

  config show             Print the effective configuration
  config set <KEY> <VAL>  Change a configuration value

\(Style.bold("OPTIONS"))
  --label <TEXT>          Name for a pairing (pair init / pair join)
  --pair <LABEL>          Which pairing to dial with, when more than one exists
  --port <N>              TCP port (default 52777)
  --duration <SECONDS>    Hold a connection for a fixed time, then exit
  --no-bonjour            Do not advertise over Bonjour when listening
  --allow-public          Accept links from outside the private address ranges
  --rebind                Let a pinned pairing bind to a different Mac
  --timeout <SECONDS>     How long `discover` browses for
  --log <LEVEL>           trace | debug | info | warn | error
  -h, --help              This help
  -v, --version           Version

\(Style.bold("WHERE THINGS LIVE"))
  \(Paths.supportDirectory.path)
      identity.json   this Mac's device id
      secrets.json    pairing keys, mode 0600
      config.json     settings

  Set \(Style.bold("CONTINUOUS_HOME")) to keep that state somewhere else.
"""

func runConfig(_ args: Args) throws {
    let sub = args.arg(0) ?? "show"
    var config = try Config.load()
    switch sub {
    case "show":
        let data = try JSONEncoder.continuousJSON.encode(config)
        out(String(data: data, encoding: .utf8) ?? "{}")
    case "set":
        let key = try args.require(1, "KEY")
        let value = try args.require(2, "VALUE")
        switch key {
        case "port":
            guard let p = UInt16(value) else {
                throw ContinuousError.invalidArgument("port must be a number between 0 and 65535")
            }
            config.port = p
        case "requireLocalNetwork", "requirePrivateNetwork":
            config.requireLocalNetwork = ["true", "yes", "1", "on"].contains(value.lowercased())
        case "bonjourEnabled":
            config.bonjourEnabled = ["true", "yes", "1", "on"].contains(value.lowercased())
        case "logLevel":
            guard LogLevel.parse(value) != nil else {
                throw ContinuousError.invalidArgument("logLevel must be trace, debug, info, warn or error")
            }
            config.logLevel = value.lowercased()
        default:
            throw ContinuousError.invalidArgument(
                "unknown config key '\(key)' — try port, requireLocalNetwork, bonjourEnabled or logLevel")
        }
        try config.save()
        ok("\(key) = \(value)")
    default:
        throw ContinuousError.invalidArgument("unknown `config` subcommand '\(sub)' — expected show or set")
    }
}

// MARK: - entry point

// Long-running commands are usually redirected to a log file. Without this, stdout switches
// to block buffering the moment it is not a terminal and the log stays empty for minutes.
setvbuf(stdout, nil, _IOLBF, 0)

let rawArgs = Array(CommandLine.arguments.dropFirst())
let command = rawArgs.first(where: { !$0.hasPrefix("-") })
let args = Args(command == nil ? rawArgs : Array(rawArgs.drop(while: { $0 != command! }).dropFirst()))

if args.has("version") || command == "version" {
    out("continuous \(Runtime.version)")
    exit(0)
}

if command == nil || args.has("help") || command == "help" {
    out(usage)
    exit(command == nil ? 1 : 0)
}

// `--log` beats the stored config; the stored config beats the default.
if let level = args.string("log").flatMap(LogLevel.parse) {
    Log.level = level
} else if let stored = (try? Config.load()).flatMap({ LogLevel.parse($0.logLevel) }) {
    Log.level = stored
}

do {
    switch command! {
    case "doctor":   try Commands.doctor(args)
    case "id":       try Commands.identity(args)
    case "selftest": try Commands.selftest(args)
    case "pair":     try Commands.pair(args)
    case "listen":   try Commands.listen(args)
    case "connect":  try Commands.connect(args)
    case "discover": try Commands.discover(args)
    case "config":   try runConfig(args)
    default:
        bad("unknown command '\(command!)'")
        out()
        out(usage)
        exit(1)
    }
} catch let e as ExitSilently {
    exit(e.code)
} catch let e as ContinuousError {
    out()
    bad(e.localizedDescription)
    exit(1)
} catch {
    out()
    bad("\(error.localizedDescription)")
    exit(1)
}
