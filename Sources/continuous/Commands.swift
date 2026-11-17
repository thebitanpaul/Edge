import Foundation
import Network
import ContinuousCore

enum Commands {

    // MARK: - id

    static func identity(_ args: Args) throws {
        let id = try Identity.loadOrCreate()
        out(Style.bold("This Mac"))
        out("  name       \(id.deviceName)")
        out("  device id  \(Style.cyan(id.deviceID.description))")
        out("  created    \(ISO8601DateFormatter().string(from: id.createdAt))")
        out("  state dir  \(Paths.supportDirectory.path)")
    }

    // MARK: - doctor

    static func doctor(_ args: Args) throws {
        let id = try Identity.loadOrCreate()
        let config = try Config.load()

        out(Style.bold("Continuous \(Runtime.version)"))
        out()

        out(Style.bold("Identity"))
        out("  \(id.deviceName)  ·  \(Style.cyan(id.deviceID.description))")
        out()

        out(Style.bold("Storage"))
        let dir = Paths.supportDirectory.path
        out("  \(dir)")
        if ProcessInfo.processInfo.environment[Paths.overrideVariable] != nil {
            info("location set by \(Paths.overrideVariable)")
        }
        for url in [Paths.identityFile, Paths.configFile, Paths.secretsFile] {
            let name = url.lastPathComponent
            if FileManager.default.fileExists(atPath: url.path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let mode = (attrs?[.posixPermissions] as? NSNumber)?.int16Value ?? 0
                let modeText = String(format: "%04o", mode & 0o777)
                let secure = (mode & 0o077) == 0
                if secure { ok("\(name) present, mode \(modeText)") }
                else { bad("\(name) mode \(modeText) is too permissive — run: chmod 600 \(url.path)") }
            } else {
                info("\(name) not created yet")
            }
        }
        out()

        out(Style.bold("Pairings"))
        do {
            let store = try SecretStore.load()
            if store.pairings.isEmpty {
                warn("none — run `continuous pair init` on the Mac that will lend its screen")
            } else {
                for p in store.pairings {
                    ok("\(p.label)  ·  key \(String(p.keyIDHex.prefix(8)))  ·  \(p.statusText)")
                }
            }
        } catch {
            bad("\(error.localizedDescription)")
        }
        out()

        out(Style.bold("Permissions"))
        let ax = Permissions.accessibility()
        let im = Permissions.inputMonitoring()
        if ax.isGranted { ok("Accessibility: granted") }
        else { warn("Accessibility: \(ax) — needed from milestone 2 onwards") }
        if im.isGranted { ok("Input Monitoring: granted") }
        else { warn("Input Monitoring: \(im) — needed from milestone 3 onwards") }
        if Permissions.isRunningInsideAppBundle {
            ok("running from an .app bundle (permissions attach to Continuous)")
        } else {
            info("running as a bare binary — permissions would attach to your terminal;")
            info("build the bundle with Scripts/build.sh before granting them")
        }
        // macOS does not expose the Local Network grant to the process that needs it, so the
        // only honest thing to say is where to look.
        info("Local Network: macOS asks the first time you connect. If the other Mac is")
        info("reachable but every link times out, check System Settings ▸ Privacy & Security ▸")
        info("Local Network and make sure Continuous is on and ticked.")
        out()

        out(Style.bold("Network"))
        out("  listen port           \(config.port == 0 ? "auto" : String(config.port))")
        out("  local network only    \(config.requireLocalNetwork ? "yes" : Style.yellow("NO — accepting any address"))")
        out("  bonjour               \(config.bonjourEnabled ? "enabled" : "disabled")")
        for (name, addr) in LocalInterfaces.list() {
            out("  \(Style.dim(name.padding(toLength: 10, withPad: " ", startingAt: 0)))\(addr)")
        }
    }

    // MARK: - pair

    static func pair(_ args: Args) throws {
        let sub = args.arg(0) ?? "list"
        switch sub {
        case "nearby", "network": try pairNearby(args)
        case "init":   try pairInit(args)
        case "join":   try pairJoin(args)
        case "list":   try pairList(args)
        case "forget": try pairForget(args)
        default:
            throw ContinuousError.invalidArgument("unknown `pair` subcommand '\(sub)' — expected nearby, init, join, list or forget")
        }
    }

    /// `continuous pair nearby` — the same exchange the menu bar runs.
    private static func pairNearby(_ args: Args) throws {
        let identity = try Identity.loadOrCreate()
        let config = try Config.load()
        let session = NetworkPairingSession(identity: identity, link: config.link)

        out()
        info("looking for another Mac that is also pairing…")
        out(Style.dim("  Run `continuous pair nearby` on the other Mac too, within two minutes."))
        out()

        let state = Box<NetworkPairingSession.Progress?>(nil)
        session.onProgress = { state.value = $0 }
        session.start()

        guard Runtime.wait(until: {
            if case .verify = state.value { return true }
            if case .failed = state.value { return true }
            return false
        }, timeout: NetworkPairing.window + 5) else {
            session.cancel()
            throw ContinuousError.timedOut("no other Mac started pairing")
        }

        if case let .failed(reason) = state.value {
            throw ContinuousError.invalidArgument(reason)
        }
        guard case let .verify(digits, peerName) = state.value else {
            throw ContinuousError.invalidArgument("pairing did not get started")
        }

        out()
        out("  Found \(Style.bold(peerName)). Both Macs should show:")
        out()
        out("      \(Style.cyan(Style.bold(digits)))")
        out()
        out("  If \(peerName) shows the same six digits, nothing is between them.")
        out("  Confirm on both Macs.")
        out()

        // No tty check: whether a person can answer is settled by whether an answer arrives.
        // Requiring a terminal also rules out piping one in, which is the only way this can
        // be tested without two people and two Macs.
        print("  Do the numbers match? [y/N] ", terminator: "")
        guard let line = readLine() else {
            session.cancel()
            throw ContinuousError.invalidArgument(
                "nothing to read an answer from — run this where you can confirm the number")
        }
        let answer = line.lowercased().trimmingCharacters(in: .whitespaces)
        guard answer == "y" || answer == "yes" else {
            session.confirm(false)
            throw ContinuousError.invalidArgument("pairing cancelled")
        }
        session.confirm(true)

        info("waiting for \(peerName) to confirm…")
        guard Runtime.wait(until: {
            if case .done = state.value { return true }
            if case .failed = state.value { return true }
            return false
        }, timeout: 120) else {
            session.cancel()
            throw ContinuousError.timedOut("\(peerName) did not confirm")
        }

        if case let .failed(reason) = state.value {
            throw ContinuousError.invalidArgument(reason)
        }
        guard case let .done(outcome) = state.value else {
            throw ContinuousError.invalidArgument("pairing did not finish")
        }

        var store = try SecretStore.load()
        // Replace rather than accumulate: a leftover from a failed attempt only makes the
        // next connection ambiguous.
        store.pairings.removeAll { $0.peerName == outcome.peerName || !$0.isBound }
        var pairing = Pairing(psk: outcome.psk, label: outcome.peerName)
        pairing.peerName = outcome.peerName
        store.pairings.append(pairing)
        try store.save()

        out()
        ok("paired with \(outcome.peerName)  ·  key \(String(pairing.keyIDHex.prefix(8)))")
        info("both Macs derived the same key, so they cannot differ")
        out(Style.dim("  Now set one Mac to share its keyboard and the other to lend its screen,"))
        out(Style.dim("  then start both:  continuous connect   /   continuous listen"))
    }

    private static func pairInit(_ args: Args) throws {
        let identity = try Identity.loadOrCreate()
        let label = args.string("label") ?? "pairing-\(Int(Date().timeIntervalSince1970) % 100000)"
        let code = PairingCode.generate()
        var store = try SecretStore.load()

        // Replace any pairing that has never been used: two outstanding codes means two
        // keys and no way to tell which one the other Mac was given.
        store.pairings.removeAll { !$0.isBound }
        if store.pairings.contains(where: { $0.label == label }) {
            throw ContinuousError.invalidArgument("a pairing labelled '\(label)' already exists — pick another --label or `pair forget` it first")
        }

        let pairing = Pairing(psk: code.psk, label: label)
        store.pairings.append(pairing)
        try store.save()

        out()
        out(Style.bold("  Pairing code for \(identity.deviceName)"))
        out()
        out("      \(Style.cyan(Style.bold(code.formatted)))")
        out()
        out(Style.dim("  Type this on the other Mac:"))
        out("      continuous pair join \(code.formatted) --label \"\(identity.deviceName)\"")
        out()
        out(Style.dim("  The code carries 128 bits of secret. Treat it like a password:"))
        out(Style.dim("  anyone who sees it can connect until this pairing binds to a device."))
        out(Style.dim("  Stored locally as key \(String(pairing.keyIDHex.prefix(8))) in \(Paths.secretsFile.path)"))
        out()
    }

    private static func pairJoin(_ args: Args) throws {
        let raw = try args.require(1, "CODE")
        let code = try PairingCode.parse(raw)
        let label = args.string("label") ?? "pairing-\(String(Crypto.hex(Crypto.deriveKeyID(fromPSK: code.psk)).prefix(6)))"
        var store = try SecretStore.load()

        let psk = code.psk
        if let existing = store.pairings.first(where: { Crypto.constantTimeEquals($0.psk, psk) }) {
            warn("this code is already stored as '\(existing.label)' — nothing to do")
            return
        }
        store.pairings.removeAll { !$0.isBound }
        if store.pairings.contains(where: { $0.label == label }) {
            throw ContinuousError.invalidArgument("a pairing labelled '\(label)' already exists — pick another --label")
        }

        let pairing = Pairing(psk: psk, label: label)
        store.pairings.append(pairing)
        try store.save()
        ok("paired as '\(label)' (key \(String(pairing.keyIDHex.prefix(8))))")
        out(Style.dim("  Next: run `continuous listen` on the other Mac, then `continuous connect <its-name-or-ip>` here."))
    }

    private static func pairList(_ args: Args) throws {
        let store = try SecretStore.load()
        guard !store.pairings.isEmpty else {
            warn("no pairings yet")
            out(Style.dim("  continuous pair init          on the Mac that lends its screen"))
            out(Style.dim("  continuous pair join <CODE>   on the Mac with the keyboard"))
            return
        }
        let pending = store.pairings.filter { !$0.isBound }.count
        if pending > 0 {
            info("\(pending) pairing\(pending == 1 ? "" : "s") set up but never used — "
                 + "they are not paired Macs until a connection succeeds")
        }
        out(Style.bold("  LABEL                 KEY       PEER                  LAST SEEN     ENDPOINT"))
        for p in store.pairings {
            let label = p.label.padding(toLength: 20, withPad: " ", startingAt: 0)
            let key = String(p.keyIDHex.prefix(8))
            let peer = (p.peerDeviceID.map { "\($0.short) \(p.peerName ?? "")" } ?? "— unbound —")
                .padding(toLength: 20, withPad: " ", startingAt: 0)
            let seen = relativeTime(p.lastSeenAt).padding(toLength: 12, withPad: " ", startingAt: 0)
            out("  \(label)  \(key)  \(peer)  \(seen)  \(p.lastEndpoint ?? "")")
        }
    }

    private static func pairForget(_ args: Args) throws {
        let needle = try args.require(1, "LABEL|KEY|DEVICE-ID")
        var store = try SecretStore.load()
        let idx = try store.index(matching: needle)
        let removed = store.pairings.remove(at: idx)
        try store.save()
        ok("forgot pairing '\(removed.label)' — that key will no longer be accepted")
    }

    // MARK: - discover

    static func discover(_ args: Args) throws {
        let timeout = try args.double("timeout") ?? 3
        info("browsing for \(LinkListener.bonjourServiceType) for \(Int(timeout))s…")
        let peers = Discovery.scan(duration: timeout)
        guard !peers.isEmpty else {
            warn("nothing found")
            out(Style.dim("  Make sure `continuous listen` is running on the other Mac and both are on the same network."))
            out(Style.dim("  Bonjour does not cross most corporate VLANs — you can always connect by IP address."))
            return
        }
        out(Style.bold("  NAME                            DEVICE ID    ROLE"))
        for p in peers {
            let name = p.serviceName.padding(toLength: 30, withPad: " ", startingAt: 0)
            let id = (p.deviceID?.short ?? "—").padding(toLength: 11, withPad: " ", startingAt: 0)
            out("  \(name)  \(id)  \(p.role ?? "—")")
        }
        out()
        out(Style.dim("  Connect with:  continuous connect \"<NAME>\""))
    }
}

// MARK: - Interface listing for `doctor`

enum LocalInterfaces {
    /// Non-loopback IPv4 addresses, so the user can see which address to type on the other Mac.
    static func list() -> [(String, String)] {
        var result: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let size = socklen_t(sa.pointee.sa_len)
            guard getnameinfo(sa, size, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }

            let name = String(cString: cur.pointee.ifa_name)
            let addr = String(cString: host)
            // bridge* is what a Thunderbolt / USB-C cable between two Macs shows up as.
            let note = name.hasPrefix("bridge") ? "  \(Style.dim("(thunderbolt / usb-c bridge)"))" : ""
            result.append((name, addr + note))
        }
        return result
    }
}
