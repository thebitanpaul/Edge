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
      continuous connect                 \(Style.dim("# no argument needed with one pairing"))

  Then push the pointer off the edge of your screen towards the other Mac.
  Hold \(Style.bold("⌘ ⌥ ⌃ ⇧")) together to bring it straight back at any time.

  \(Style.dim("A target may be a pairing label, a device id, a Bonjour name or an address."))

\(Style.bold("COMMANDS"))
  doctor                  Environment, permissions, pairings and network report
  id                      Show this Mac's device identity
  selftest                Run the full crypto + transport check over loopback
  permissions             Show privacy permissions, and how to grant them

  pair init               Generate a pairing code on this Mac
  pair join <CODE>        Accept a pairing code from the other Mac
  pair list               Show stored pairings
  pair forget <NAME>      Delete a pairing and stop accepting its key

  listen                  Accept links from a paired Mac, and act on what it sends
  connect [HOST|NAME]     Share this Mac's keyboard and mouse with a paired Mac
  discover                Browse the local network for listening Macs

  menubar                 Run the menu-bar front end (also what double-clicking does)
  status                  What is running right now, and where the pointer is
  troubleshoot            Work out why the two Macs are not talking
  service install <ROLE>  Start at login as `listen` or `connect`
  service start|stop      Control the login item
  service uninstall       Remove it

  layout                  Show how both Macs' screens combine into one desktop
  layout set <EDGE>       Where the other Mac sits: left, right, top or bottom
  inject-test             Move this Mac's own pointer, to check Accessibility
  capture-test            Check this Mac can capture input, without connecting
  cursor-doctor           Measure whether this Mac's cursor can be held still
  remote-test [HOST]      Drive the OTHER Mac's pointer across the link

  config show             Print the effective configuration
  config set <KEY> <VAL>  Change a configuration value

\(Style.bold("OPTIONS"))
  --label <TEXT>          Name for a pairing (pair init / pair join)
  --pair <LABEL>          Which pairing to dial with, when more than one exists
  --alignment <MODE>      proportional | start | center | end (layout set)
  --keys                  Also exercise keyboard injection in the test commands
  --force                 Listen even without Accessibility granted
  --port <N>              TCP port (default 52777)
  --duration <SECONDS>    Hold a connection for a fixed time, then exit
  --link-only             Connect without capturing this Mac's keyboard or mouse
  --no-retry              Do not reconnect automatically when the link drops
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
        case "remoteEdge":
            guard ScreenEdge.parse(value) != nil else {
                throw ContinuousError.invalidArgument("remoteEdge must be left, right, top or bottom")
            }
            config.remoteEdge = value.lowercased()
        case "remoteAlignment":
            guard let a = ScreenAlignment.parse(value) else {
                throw ContinuousError.invalidArgument("remoteAlignment must be proportional, start, center or end")
            }
            config.remoteAlignment = a.rawValue
        case "edgePressure":
            guard let n = Double(value), n >= 1, n <= 200 else {
                throw ContinuousError.invalidArgument("edgePressure must be a number between 1 and 200 (points of push)")
            }
            config.edgePressure = n
        case "clipboardSharing":
            config.clipboardSharing = ["true", "yes", "1", "on"].contains(value.lowercased())
        case "clipboardImages":
            config.clipboardImages = ["true", "yes", "1", "on"].contains(value.lowercased())
        case "clipboardLimit":
            guard let n = Int(value), n >= 1024 else {
                throw ContinuousError.invalidArgument("clipboardLimit is a byte count of at least 1024")
            }
            config.clipboardLimit = n
        case "holdLocalPointer":
            config.holdLocalPointer = ["true", "yes", "1", "on"].contains(value.lowercased())
        case "logLevel":
            guard LogLevel.parse(value) != nil else {
                throw ContinuousError.invalidArgument("logLevel must be trace, debug, info, warn or error")
            }
            config.logLevel = value.lowercased()
        default:
            throw ContinuousError.invalidArgument(
                "unknown config key '\(key)' — try port, requireLocalNetwork, bonjourEnabled, remoteEdge, remoteAlignment, edgePressure, clipboardSharing or logLevel")
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

// Double-clicking the app, or `open -a Continuous`, launches it with no arguments and no
// terminal attached. That is the menu-bar front end. Typing `continuous` in a shell still
// prints the usage, because there a human is waiting to read it.
let launchedFromFinder = command == nil && !args.has("help") && isatty(STDIN_FILENO) == 0
if command == "menubar" || launchedFromFinder {
    runMenuBar()
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
    case "doctor":      try Commands.doctor(args)
    case "id":          try Commands.identity(args)
    case "selftest":    try Commands.selftest(args)
    case "permissions": try Commands.permissions(args)
    case "status":      try Commands.status(args)
    case "troubleshoot", "why":
                        try Commands.troubleshoot(args)
    case "service":     try Commands.service(args)
    case "layout":      try Commands.layout(args)
    case "inject-test", "selftest-inject":
                        try Commands.injectTest(args)
    case "capture-test", "selftest-capture":
                        try Commands.captureTest(args)
    case "cursor-doctor":
                        try Commands.cursorDoctor(args)
    case "remote-test", "selftest-remote":
                        try Commands.remoteTest(args)
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
