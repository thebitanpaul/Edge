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

    private func refresh() {
        lastKnownState = currentState

        // Only redraw when it would differ. Touching an NSStatusItem button makes AppKit
        // reconsider the cursor, and doing that twice a second un-hides the cursor the
        // session is holding hidden while the pointer is on the other Mac — which is how the
        // menu-bar front end ended up leaving a visible pointer behind and the terminal did not.
        let signature = iconSignature
        if signature != lastIconSignature {
            lastIconSignature = signature
            redrawIcon()
        }
        // The menu is rebuilt when it opens; rebuilding it while closed is invisible work.
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
        if !isRunning {
            menu.addItem(disabled("Not running"))
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
            menu.addItem(disabled(mode == .host ? "Looking for the other Mac…" : "Waiting for the other Mac…"))
            if let error = state?.lastError { menu.addItem(disabled(error)) }
        }

        menu.addItem(.separator())
        menu.addItem(action(isRunning ? "Stop" : "Start", #selector(toggleRunning)))

        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
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
            store.pairings.append(Pairing(psk: code.psk, label: "Mac \(store.pairings.count + 1)"))
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
            store.pairings.append(Pairing(psk: code.psk, label: "Mac \(store.pairings.count + 1)"))
            try store.save()
            notify("Paired", "Press Start on both Macs. This one is set to: \(mode.title).")
        } catch {
            notify("That code was not accepted", error.localizedDescription)
        }
        refresh()
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
              let chosen = Mode(rawValue: raw), chosen != mode else { return }
        let wasRunning = isRunning
        stopSession()
        mode = chosen
        UserDefaults.standard.set(chosen.rawValue, forKey: "mode")
        if wasRunning { startSession() }
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
