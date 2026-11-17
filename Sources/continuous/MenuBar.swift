import AppKit
import Foundation
import ContinuousCore

/// A menu-bar front end, so this does not have to live in a terminal window.
///
/// It supervises rather than reimplements: the session runs as a child process — the same
/// binary with `connect` or `listen` — and this watches the state file the session already
/// publishes. Two benefits worth the extra process. A session that dies takes the pointer with
/// it and not the user interface, so there is always something left to click "Start" on. And
/// there is exactly one implementation of the session, used by both front ends, so the thing
/// you debug from the terminal is the thing the menu runs.
final class MenuBarController: NSObject, NSMenuDelegate {

    enum Mode: String {
        case host    // share this Mac's keyboard and mouse
        case client  // lend this Mac's screen

        var argument: String { self == .host ? "connect" : "listen" }
        var title: String {
            self == .host ? "Share my keyboard & mouse" : "Lend my screen"
        }
        var runtimeRole: RuntimeState.Role { self == .host ? .sharing : .listening }
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var session: Process?
    private var refreshTimer: Timer?
    private var mode: Mode
    private var lastKnownState: RuntimeState?
    private var lastIconSignature = ""
    private var blinkTimer: Timer?
    private var blinkOn = true

    private var logURL: URL { Paths.supportDirectory.appendingPathComponent("session.log") }

    override init() {
        let stored = UserDefaults.standard.string(forKey: "mode").flatMap(Mode.init(rawValue:))
        self.mode = stored ?? .host
        super.init()
    }

    func start() {
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "Continuous"
        lastIconSignature = iconSignature
        redrawIcon()

        // Faster than a human notices a state change, slower than anything that matters.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    // MARK: - State

    private var currentState: RuntimeState? {
        guard let state = RuntimeState.load(mode.runtimeRole), state.isLive else { return nil }
        return state
    }

    private var isRunning: Bool {
        if let session, session.isRunning { return true }
        return currentState != nil
    }

    /// A one-line description of everything the icon depends on, so it can be redrawn only
    /// when it would actually look different.
    private var iconSignature: String {
        let state = lastKnownState
        return [isRunning ? "run" : "stop",
                state?.connected == true ? "up" : "down",
                state?.pointerIsRemote == true ? "away" : "here"].joined(separator: "/")
    }

    private var pointerIsAway: Bool { lastKnownState?.pointerIsRemote == true }

    /// Running but not yet connected — the state worth animating.
    private var isSearching: Bool { isRunning && lastKnownState?.connected != true }

    private func refresh() {
        lastKnownState = currentState
        updateBlinking()

        // Only redraw when it would differ. Touching an NSStatusItem button makes AppKit
        // reconsider the cursor, and doing that twice a second un-hid the cursor the session
        // was holding hidden — which is how the menu-bar front end left a visible pointer
        // behind on a screen nobody was using, and the terminal did not.
        let signature = iconSignature
        if signature != lastIconSignature {
            lastIconSignature = signature
            redrawIcon()
        }
        // The menu is rebuilt when it opens; rebuilding it while closed is invisible work.
    }

    /// Blinks while searching for the other Mac, and only then.
    ///
    /// Never while the pointer is away: each blink touches the status button, and that is
    /// exactly what un-hides the cursor on this Mac.
    private func updateBlinking() {
        let shouldBlink = isSearching && !pointerIsAway
        if shouldBlink, blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.blinkOn.toggle()
                self.statusItem.button?.alphaValue = self.blinkOn ? 1.0 : 0.35
            }
        } else if !shouldBlink, blinkTimer != nil {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkOn = true
            statusItem.button?.alphaValue = 1.0
        }
    }

    private func redrawIcon() {
        guard let button = statusItem.button else { return }
        let state = lastKnownState
        let symbol: String
        let description: String

        if !isRunning {
            symbol = "cursorarrow.slash"
            description = "Continuous — stopped"
        } else if state?.connected != true {
            symbol = "cursorarrow"
            description = "Continuous — connecting"
        } else if state?.pointerIsRemote == true {
            symbol = "arrow.right.to.line"
            description = "Continuous — pointer is on the other Mac"
        } else {
            symbol = "cursorarrow.rays"
            description = "Continuous — connected"
        }

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) {
            image.isTemplate = true     // so it follows light and dark menu bars
            button.image = image
            button.title = ""
        } else {
            // Every supported macOS has these symbols; the fallback is for the one that does not.
            button.image = nil
            button.title = isRunning ? "◉" : "○"
        }
        button.toolTip = description
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        lastKnownState = currentState
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let state = lastKnownState

        // What is happening, in the first two lines, without having to read a log.
        let paired = !(((try? SecretStore.load()) ?? SecretStore()).pairings.isEmpty)

        if !paired {
            menu.addItem(disabled("Not set up yet"))
            menu.addItem(action("Set up…", #selector(runSetup)))
            menu.addItem(.separator())
            menu.addItem(action("Quit Continuous", #selector(quit)))
            return
        }

        if !isRunning {
            menu.addItem(disabled("Not running"))
            menu.addItem(disabled("This Mac: \(mode.title.lowercased())"))
        } else if let state, state.connected {
            menu.addItem(disabled("Connected to \(state.peerName ?? "the other Mac")"))
            if mode == .host {
                menu.addItem(disabled(state.pointerIsRemote == true
                                      ? "Pointer is on \(state.peerName ?? "the other Mac")"
                                      : "Pointer is on this Mac"))
            }
            var detail: [String] = []
            if let rtt = state.rttMillis { detail.append(String(format: "round trip %.1f ms", rtt)) }
            if state.clipboardActive { detail.append("clipboard shared") }
            if !detail.isEmpty { menu.addItem(disabled(detail.joined(separator: " · "))) }
        } else {
            menu.addItem(disabled(mode == .host ? "Looking for the other Mac…"
                                                : "Waiting for the other Mac…"))
            menu.addItem(disabled(waitingHint))
            if let error = state?.lastError { menu.addItem(disabled(error)) }
        }

        menu.addItem(.separator())
        menu.addItem(action(isRunning ? "Stop" : "Start", #selector(toggleRunning)))

        let modeItem = NSMenuItem(title: "This Mac", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        modeMenu.addItem(disabled("The other Mac must be set to the opposite"))
        for candidate in [Mode.host, .client] {
            let item = NSMenuItem(title: candidate.title, action: #selector(selectMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = candidate == mode ? .on : .off
            item.representedObject = candidate.rawValue
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(.separator())
        menu.addItem(action("Set up…", #selector(runSetup)))
        menu.addItem(devicesMenuItem())
        menu.addItem(arrangementMenuItem())
        menu.addItem(.separator())

        let config = (try? Config.load()) ?? Config()
        let clipboard = action("Share clipboard", #selector(toggleClipboard))
        clipboard.state = config.clipboardSharing ? .on : .off
        menu.addItem(clipboard)

        let login = action("Start at login", #selector(toggleLoginItem))
        login.state = LaunchAgent.installedRole != nil ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action("Open log…", #selector(openLog)))
        menu.addItem(disabled(Runtime.version))
        menu.addItem(.separator())
        menu.addItem(action("Quit Continuous", #selector(quit)))
    }

    // MARK: Setup

    /// One place that explains the two decisions and makes both of them, in order.
    ///
    /// They were previously separate menu items with nothing tying them together, and the
    /// result was a reasonable question with no answer in the interface: does it matter which
    /// Mac shows the pairing code, and does that decide which one shares its keyboard? (No,
    /// and no.) Pairing is symmetric; the role is a separate choice; and if both Macs pick the
    /// same role nothing connects and nothing says why.
    @objc private func runSetup() {
        let roleAlert = NSAlert()
        roleAlert.messageText = "What should this Mac do?"
        roleAlert.informativeText =
            "Continuous needs one Mac of each kind.\n\n"
            + "Share its keyboard & mouse — you use this Mac's keyboard, and the pointer "
            + "crosses onto the other screen.\n\n"
            + "Lend its screen — this Mac is driven by the other one's keyboard.\n\n"
            + "Set the other Mac to the opposite. If both are set the same, neither will "
            + "connect."
        roleAlert.addButton(withTitle: "Share its keyboard & mouse")
        roleAlert.addButton(withTitle: "Lend its screen")
        roleAlert.addButton(withTitle: "Cancel")

        let answer = roleAlert.runModal()
        guard answer != .alertThirdButtonReturn else { return }
        setMode(answer == .alertFirstButtonReturn ? .host : .client, restart: false)

        let store = (try? SecretStore.load()) ?? SecretStore()
        if !store.pairings.isEmpty {
            notify("Set to: \(mode.title)",
                   "This Mac is already paired. Press Start here and on the other Mac.")
            refresh()
            return
        }

        let pairAlert = NSAlert()
        pairAlert.messageText = "Pair the two Macs"
        pairAlert.informativeText =
            "The two Macs share one secret code. It does not matter which one creates it, and "
            + "it has no bearing on which Mac shares its keyboard — you have just chosen that "
            + "separately.\n\n"
            + "Create the code on whichever Mac you are sitting at, then type it on the other."
        pairAlert.addButton(withTitle: "Create a code")
        pairAlert.addButton(withTitle: "I have a code")
        pairAlert.addButton(withTitle: "Later")

        switch pairAlert.runModal() {
        case .alertFirstButtonReturn: pairNewMac()
        case .alertSecondButtonReturn: enterPairingCode()
        default: break
        }
        refresh()
    }

    /// A short line naming the likeliest reason nothing has connected yet.
    ///
    /// The commonest by far is both Macs set to the same role, and because neither one dials
    /// in that case there is nothing in any log to notice.
    private var waitingHint: String {
        mode == .host
            ? "Make sure the other Mac is set to “Lend my screen”"
            : "Make sure the other Mac is set to “Share my keyboard & mouse”"
    }

    // MARK: Devices

    private func devicesMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Devices", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let store = (try? SecretStore.load()) ?? SecretStore()

        if store.pairings.isEmpty {
            submenu.addItem(disabled("No Macs paired yet"))
        } else {
            for pairing in store.pairings {
                let name = pairing.peerName ?? pairing.label
                let connected = lastKnownState?.connected == true
                    && lastKnownState?.peerName == pairing.peerName
                let entry = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                entry.state = connected ? .on : .off

                let detail = NSMenu()
                detail.addItem(disabled(pairing.isBound
                                        ? "Paired \(relativeTime(pairing.createdAt))"
                                        : "Waiting for its first connection"))
                if let endpoint = pairing.lastEndpoint {
                    detail.addItem(disabled("Last seen at \(endpoint)"))
                }
                detail.addItem(.separator())
                let forget = NSMenuItem(title: "Forget \(name)…",
                                        action: #selector(forgetDevice(_:)), keyEquivalent: "")
                forget.target = self
                forget.representedObject = pairing.label
                detail.addItem(forget)
                entry.submenu = detail
                submenu.addItem(entry)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(action("Pair a new Mac…", #selector(pairNewMac)))
        submenu.addItem(action("Enter a pairing code…", #selector(enterPairingCode)))
        item.submenu = submenu
        return item
    }

    @objc private func pairNewMac() {
        let code = PairingCode.generate()
        do {
            var store = try SecretStore.load()
            store.pairings.append(Pairing(psk: code.psk, label: Self.freshLabel(in: store)))
            try store.save()
        } catch {
            notify("Could not create a pairing", error.localizedDescription)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Pairing code"
        alert.informativeText =
            "Type this on the other Mac, under Devices ▸ Enter a pairing code.\n\n"
            + code.formatted
            + "\n\nIt carries 128 bits of secret. Treat it like a password: anyone who sees it "
            + "can connect until the pairing binds to a Mac, which happens the first time one "
            + "uses it."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code.formatted, forType: .string)
        }
        refresh()
    }

    @objc private func enterPairingCode() {
        let alert = NSAlert()
        alert.messageText = "Enter a pairing code"
        alert.informativeText = "Generated by the other Mac under Devices ▸ Pair a new Mac."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX"
        alert.accessoryView = field
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let code = try PairingCode.parse(field.stringValue)
            var store = try SecretStore.load()
            guard !store.pairings.contains(where: { Crypto.constantTimeEquals($0.psk, code.psk) })
            else {
                notify("Already paired", "This Mac already knows that code.")
                return
            }
            store.pairings.append(Pairing(psk: code.psk, label: Self.freshLabel(in: store)))
            try store.save()
            notify("Paired",
                   "Press Start on both Macs. This one is set to: \(mode.title). "
                   + "The other must be set to the opposite.")
        } catch {
            notify("That code was not accepted", error.localizedDescription)
        }
        refresh()
    }

    /// A label nothing else is using. Counting the pairings is not enough: forget the first
    /// of two and the count gives back a name that is already taken, and a duplicate label
    /// cannot be told apart when choosing which pairing to dial with.
    private static func freshLabel(in store: SecretStore) -> String {
        let taken = Set(store.pairings.map(\.label))
        var n = 1
        while taken.contains("Mac \(n)") { n += 1 }
        return "Mac \(n)"
    }

    @objc private func forgetDevice(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        let confirm = NSAlert()
        confirm.messageText = "Forget this Mac?"
        confirm.informativeText =
            "Its key will no longer be accepted, and you will need a new pairing code to "
            + "connect the two Macs again."
        confirm.addButton(withTitle: "Forget")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            var store = try SecretStore.load()
            store.pairings.removeAll { $0.label == label }
            try store.save()
            if isRunning { stopSession() }
        } catch {
            notify("Could not forget it", error.localizedDescription)
        }
        refresh()
    }

    // MARK: Arrangement

    private func arrangementMenuItem() -> NSMenuItem {
        let config = (try? Config.load()) ?? Config()
        let item = NSMenuItem(title: "Screen arrangement", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        submenu.addItem(disabled("The other Mac is to my…"))
        for edge in ScreenEdge.allCases {
            let title: String
            switch edge {
            case .left: title = "Left"
            case .right: title = "Right"
            case .top: title = "Above"
            case .bottom: title = "Below"
            }
            let entry = NSMenuItem(title: title, action: #selector(selectEdge(_:)), keyEquivalent: "")
            entry.target = self
            entry.state = config.edge == edge ? .on : .off
            entry.representedObject = edge.rawValue
            submenu.addItem(entry)
        }

        submenu.addItem(.separator())
        submenu.addItem(disabled("When the screens are different sizes…"))
        for alignment in ScreenAlignment.allCases {
            let title: String
            switch alignment {
            case .proportional: title = "Stretch to fit (recommended)"
            case .start: title = "Line up the tops"
            case .center: title = "Line up the middles"
            case .end: title = "Line up the bottoms"
            }
            let entry = NSMenuItem(title: title, action: #selector(selectAlignment(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.state = config.alignment == alignment ? .on : .off
            entry.representedObject = alignment.rawValue
            submenu.addItem(entry)
        }

        submenu.addItem(.separator())
        submenu.addItem(action("Show arrangement…", #selector(showArrangement)))
        item.submenu = submenu
        return item
    }

    @objc private func selectEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        applyConfig { $0.remoteEdge = raw }
    }

    @objc private func selectAlignment(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        applyConfig { $0.remoteAlignment = raw }
    }

    /// Saves a change and restarts the session, because the arrangement is read when a
    /// session starts rather than watched while it runs.
    private func applyConfig(_ change: (inout Config) -> Void) {
        var config = (try? Config.load()) ?? Config()
        change(&config)
        try? config.save()
        if isRunning {
            stopSession()
            startSession()
        }
        refresh()
    }

    @objc private func showArrangement() {
        let store = (try? SecretStore.load()) ?? SecretStore()
        let config = (try? Config.load()) ?? Config()

        guard let pairing = store.pairings.first(where: { ($0.peerDisplays?.isEmpty == false) }),
              let remote = pairing.peerDisplays,
              let layout = ScreenLayout(localDisplays: Displays.current(), remoteDisplays: remote,
                                        edge: config.edge, alignment: config.alignment) else {
            notify("No arrangement yet",
                   "Connect once and the other Mac's screens will be remembered here.")
            return
        }

        let name = pairing.peerName ?? pairing.label
        let alert = NSAlert()
        alert.messageText = "\(name) is to the \(config.remoteEdge)"
        // A proportional font would turn the diagram into noise.
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 140))
        text.string = layout.diagram(width: 72, localName: "this Mac", remoteName: name)
        text.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        text.isEditable = false
        text.drawsBackground = false
        alert.accessoryView = text
        alert.informativeText = "# this Mac   + \(name)   ·   alignment: \(config.remoteAlignment)"
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func toggleRunning() {
        isRunning ? stopSession() : startSession()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let chosen = Mode(rawValue: raw) else { return }
        setMode(chosen, restart: true)
    }

    private func setMode(_ chosen: Mode, restart: Bool) {
        guard chosen != mode else { return }
        let wasRunning = isRunning
        stopSession()
        mode = chosen
        UserDefaults.standard.set(chosen.rawValue, forKey: "mode")
        if restart && wasRunning { startSession() }
        refresh()
    }

    @objc private func toggleClipboard() {
        var config = (try? Config.load()) ?? Config()
        config.clipboardSharing.toggle()
        try? config.save()

        if config.clipboardSharing {
            notify("Clipboard sharing on",
                   "Both Macs must have it on. Whatever you copy is sent to the other Mac.")
        }
        // The setting is read when a session starts, so an existing one has to be restarted.
        if isRunning {
            stopSession()
            startSession()
        }
        refresh()
    }

    @objc private func toggleLoginItem() {
        do {
            if LaunchAgent.installedRole != nil {
                try LaunchAgent.uninstall()
            } else {
                try LaunchAgent.install(role: mode.runtimeRole, extraArguments: [])
                try LaunchAgent.start()
            }
        } catch {
            notify("Could not change the login item", error.localizedDescription)
        }
        refresh()
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? Paths.ensureSupportDirectory()
            FileManager.default.createFile(atPath: logURL.path, contents: Data())
        }
        NSWorkspace.shared.open(logURL)
    }

    @objc private func quit() {
        blinkTimer?.invalidate()
        stopSession()
        NSApp.terminate(nil)
    }

    // MARK: - The session process

    private func startSession() {
        guard session?.isRunning != true else { return }
        guard let executable = Bundle.main.executableURL else {
            notify("Cannot start", "Continuous could not find its own binary.")
            return
        }

        try? Paths.ensureSupportDirectory()
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: Data())
        }
        guard let log = try? FileHandle(forWritingTo: logURL) else {
            notify("Cannot start", "Could not open \(logURL.lastPathComponent).")
            return
        }
        log.seekToEndOfFile()
        log.write(Data("\n--- \(Date()) · starting \(mode.argument) ---\n".utf8))

        if let other = RuntimeState.existing(mode.runtimeRole) {
            let alert = NSAlert()
            alert.messageText = "Already running"
            alert.informativeText =
                "Another Continuous session is already doing this on this Mac (pid \(other.pid)) "
                + "— probably one started from a terminal, or a login item.\n\n"
                + "Two at once means two event taps and doubled traffic, which feels like a "
                + "laggy pointer and a cursor that will not stay hidden."
            alert.addButton(withTitle: "Take over")
            alert.addButton(withTitle: "Leave it")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            kill(other.pid, SIGINT)
            let deadline = Date().addingTimeInterval(4)
            while RuntimeState.existing(mode.runtimeRole) != nil && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
        }

        let process = Process()
        process.executableURL = executable
        // --no-prompt because a permission dialog raised from a background child process is
        // confusing; the menu reports what is missing instead.
        process.arguments = [mode.argument, "--no-prompt"]
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.session = nil
                if finished.terminationStatus != 0 && finished.terminationReason != .uncaughtSignal {
                    self.notify("Continuous stopped",
                                "The session exited. Open the log from the menu to see why.")
                }
                self.refresh()
            }
        }

        do {
            try process.run()
            session = process
        } catch {
            notify("Could not start", error.localizedDescription)
        }
        refresh()
    }

    private func stopSession() {
        // SIGINT rather than terminate(): the session handles it, which means it gives this
        // Mac its pointer back and un-hides the cursor on the way out.
        if let session, session.isRunning {
            kill(session.processIdentifier, SIGINT)
            let deadline = Date().addingTimeInterval(2)
            while session.isRunning && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if session.isRunning { session.terminate() }
        }
        session = nil

        // A session started by the login item is not our child, so ask launchd instead.
        if currentState != nil { try? LaunchAgent.stop() }
        refresh()
    }

    private func notify(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.runModal()
    }
}

/// Runs the menu-bar front end until the user quits.
func runMenuBar() -> Never {
    let app = NSApplication.shared
    // Accessory: a menu-bar item, no Dock icon, no main window.
    app.setActivationPolicy(.accessory)
    let controller = MenuBarController()
    controller.start()
    app.run()
    exit(0)
}
