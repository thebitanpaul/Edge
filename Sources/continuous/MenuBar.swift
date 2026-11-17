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
        /// "Primary" and "secondary" rather than "share" and "lend".
        ///
        /// The old wording described what each Mac does for the other, which is the wrong
        /// way round for someone deciding which to pick: you know which Mac you are sitting
        /// at long before you know what it will be doing for the other one.
        var title: String {
            self == .host ? "Primary — this Mac's keyboard and mouse"
                          : "Secondary — controlled by the other Mac"
        }

        var shortTitle: String { self == .host ? "Primary" : "Secondary" }

        var opposite: Mode { self == .host ? .client : .host }
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
        // No tooltip. AppKit leaves one floating beside the cursor after the menu has been
        // opened and closed, and it follows you around until you hover the icon again. The
        // first line of the menu says the same thing, in a place that behaves.
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
        _ = description
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        lastKnownState = currentState
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let state = lastKnownState
        let store = (try? SecretStore.load()) ?? SecretStore()

        if store.pairings.filter(\.isBound).isEmpty && store.pairings.isEmpty {
            menu.addItem(disabled("Not set up"))
            menu.addItem(action("Set up…", #selector(runSetup)))
            menu.addItem(.separator())
            menu.addItem(action("Quit", #selector(quit)))
            return
        }

        // Status, in as few lines as will carry it.
        if !isRunning {
            menu.addItem(disabled("Stopped · \(mode.shortTitle)"))
        } else if let state, state.connected {
            let peer = state.peerName ?? "the other Mac"
            menu.addItem(disabled(mode == .host && state.pointerIsRemote == true
                                  ? "Pointer on \(peer)"
                                  : "Connected · \(peer)"))
            if let rtt = state.rttMillis {
                menu.addItem(disabled(String(format: "%.0f ms%@", rtt,
                                             state.clipboardActive ? " · clipboard" : "")))
            }
        } else {
            menu.addItem(disabled("Connecting…"))
            menu.addItem(disabled(waitingHint))
        }

        menu.addItem(.separator())
        menu.addItem(action(isRunning ? "Stop" : "Start", #selector(toggleRunning)))

        let modeItem = NSMenuItem(title: "This Mac: \(mode.shortTitle)", action: nil,
                                  keyEquivalent: "")
        let modeMenu = NSMenu()
        for candidate in [Mode.host, .client] {
            let entry = NSMenuItem(title: candidate.title, action: #selector(selectMode(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.state = candidate == mode ? .on : .off
            entry.representedObject = candidate.rawValue
            modeMenu.addItem(entry)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(.separator())
        menu.addItem(devicesMenuItem())
        menu.addItem(arrangementMenuItem())
        // Only where it does something. A secondary Mac listens on everything it has, so the
        // choice has no effect there and offering it only invites someone to set it wrongly.
        if mode == .host { menu.addItem(linkMenuItem()) }

        let config = (try? Config.load()) ?? Config()
        menu.addItem(.separator())
        let clipboard = action("Share clipboard", #selector(toggleClipboard))
        clipboard.state = config.clipboardSharing ? .on : .off
        menu.addItem(clipboard)

        let login = action("Start at login", #selector(toggleLoginItem))
        login.state = LaunchAgent.installedRole != nil ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(helpMenuItem())
        menu.addItem(action("Quit", #selector(quit)))
    }

    /// Everything worth having and not worth reading every time the menu opens.
    private func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(action("Set up again…", #selector(runSetup)))
        submenu.addItem(.separator())
        submenu.addItem(action("Why is it not connecting?…", #selector(troubleshoot)))
        submenu.addItem(action("Open log…", #selector(openLog)))
        submenu.addItem(.separator())
        submenu.addItem(disabled(Runtime.version))
        item.submenu = submenu
        return item
    }

    private func linkMenuItem() -> NSMenuItem {
        let config = (try? Config.load()) ?? Config()
        let hasCable = NetworkAddress.localAddresses().contains(where: NetworkAddress.isLinkLocalIPv4)
        let item = NSMenuItem(title: "Connect over", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for choice in LinkPreference.allCases {
            let entry = NSMenuItem(title: choice.title, action: #selector(selectLink(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.state = config.link == choice ? .on : .off
            entry.representedObject = choice.rawValue
            // Saying "no cable" is more use than letting someone pick one that is not there.
            if choice == .cable && !hasCable {
                entry.isEnabled = false
                entry.title = "Cable — none connected"
            }
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    // MARK: Setup

    /// One screen, one decision, and pairing starts straight away.
    ///
    /// It used to ask which role, then ask separately whether to pair, then open a third
    /// window to do it. Three steps for what is really one question — *which Mac am I sitting
    /// at?* — and the wording described each Mac in terms of what it does for the other,
    /// which is the wrong way round for someone trying to choose.
    @objc private func runSetup() {
        let alert = NSAlert()
        alert.messageText = "Which Mac is this?"
        alert.informativeText =
            "Set the other Mac to the opposite.\n\n"
            + "Both Macs need the same Wi-Fi network, or a USB-C cable between them."
        alert.addButton(withTitle: "Primary — I use this keyboard")
        alert.addButton(withTitle: "Secondary — controlled by the other")
        alert.addButton(withTitle: "Cancel")

        let answer = alert.runModal()
        guard answer != .alertThirdButtonReturn else { return }
        setMode(answer == .alertFirstButtonReturn ? .host : .client, restart: false)

        let store = (try? SecretStore.load()) ?? SecretStore()
        guard store.pairings.filter(\.isBound).isEmpty else {
            notify("Set as \(mode.shortTitle)",
                   "Already paired. Set the other Mac to \(mode.opposite.shortTitle), then "
                   + "Start on both.")
            refresh()
            return
        }
        // Straight into pairing: choosing a role and then being asked whether you would also
        // like to pair is a question with only one sensible answer.
        pairNearby()
    }

    /// A short line naming the likeliest reason nothing has connected yet.
    ///
    /// The commonest by far is both Macs set to the same role, and because neither one dials
    /// in that case there is nothing in any log to notice.
    private var waitingHint: String {
        "Make sure the other Mac is set to \(mode.opposite.shortTitle)"
    }

    // MARK: Devices

    /// Lists Macs this one has actually paired with.
    ///
    /// Only Macs it has *connected to* appear here. A pairing that has been set up but never
    /// used is not a device yet — showing it as one is what made both Macs display "Mac 1"
    /// immediately after generating a code, which reads as success when nothing has happened.
    /// Unused pairings appear as a single line saying what is being waited for.
    private func devicesMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Devices", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let store = (try? SecretStore.load()) ?? SecretStore()
        let paired = store.pairings.filter(\.isBound)
        let pending = store.pairings.filter { !$0.isBound }

        if paired.isEmpty {
            submenu.addItem(disabled("No Macs paired yet"))
        } else {
            for pairing in paired {
                let connected = lastKnownState?.connected == true
                    && lastKnownState?.peerName == pairing.peerName
                let entry = NSMenuItem(title: pairing.peerName ?? pairing.label,
                                       action: nil, keyEquivalent: "")
                entry.state = connected ? .on : .off
                entry.submenu = detailMenu(for: pairing)
                submenu.addItem(entry)
            }
        }

        if let waiting = pending.first {
            submenu.addItem(.separator())
            submenu.addItem(disabled("Not connected yet"))
            let cancel = NSMenuItem(title: "Cancel this pairing", action: #selector(forgetDevice(_:)),
                                    keyEquivalent: "")
            cancel.target = self
            cancel.representedObject = waiting.label
            submenu.addItem(cancel)
        }

        submenu.addItem(.separator())
        submenu.addItem(action("Connect to a nearby Mac…", #selector(pairNearby)))
        submenu.addItem(disabled("…choose it on both Macs"))
        item.submenu = submenu
        return item
    }

    private func detailMenu(for pairing: Pairing) -> NSMenu {
        let detail = NSMenu()
        if pairing.isBound {
            detail.addItem(disabled("Paired \(relativeTime(pairing.createdAt))"))
            if let host = pairing.peerHostName { detail.addItem(disabled("Hostname \(host).local")) }
        } else {
            detail.addItem(disabled("Never connected"))
            detail.addItem(disabled("Key \(String(pairing.keyIDHex.prefix(8))) — must match the other Mac"))
        }
        if let manual = pairing.manualEndpoint, !manual.isEmpty {
            detail.addItem(disabled("Address set to \(manual)"))
        } else if let endpoint = pairing.lastEndpoint {
            detail.addItem(disabled("Last seen at \(endpoint)"))
        }

        detail.addItem(.separator())
        for (title, selector) in [("Rename…", #selector(renameDevice(_:))),
                                  ("Set address…", #selector(setDeviceAddress(_:))),
                                  ("Forget…", #selector(forgetDevice(_:)))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            entry.representedObject = pairing.label
            detail.addItem(entry)
        }
        return detail
    }

    /// Asks for one line of text, pre-filled.
    private func prompt(title: String, explanation: String, value: String,
                        placeholder: String, confirm: String) -> String? {
        // Without this the field ignores every keystroke. A menu-bar app runs as an
        // accessory and is never the active application, so its windows do not become key
        // and nothing reaches the text field — it looks broken rather than inactive.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = explanation
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async { alert.window.makeFirstResponder(field) }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func editPairing(labelled label: String, _ change: (inout Pairing) -> Void) {
        do {
            var store = try SecretStore.load()
            guard let index = store.pairings.firstIndex(where: { $0.label == label }) else { return }
            change(&store.pairings[index])
            try store.save()
        } catch {
            notify("Could not save that", error.localizedDescription)
        }
        refresh()
    }

    /// A running session reads the keys it will accept when it starts, so a pairing change
    /// means nothing to it until it is restarted. Leaving that to the user produced a failure
    /// that looks exactly like a mistyped code and cannot be fixed by re-typing it.
    private func restartForPairingChange() {
        guard isRunning else { return }
        stopSession()
        startSession()
    }

    @objc private func renameDevice(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        let store = (try? SecretStore.load()) ?? SecretStore()
        guard let pairing = store.pairings.first(where: { $0.label == label }) else { return }

        guard let name = prompt(title: "Rename this Mac",
                                explanation: "Just a name in this list.",
                                value: pairing.peerName ?? pairing.label,
                                placeholder: "Work Mac",
                                confirm: "Rename"), !name.isEmpty else { return }

        guard !store.pairings.contains(where: { $0.label != label && $0.label == name }) else {
            notify("That name is taken", "Another pairing is already called “\(name)”.")
            return
        }
        editPairing(labelled: label) { $0.label = name; $0.peerName = name }
    }

    @objc private func setDeviceAddress(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        let store = (try? SecretStore.load()) ?? SecretStore()
        guard let pairing = store.pairings.first(where: { $0.label == label }) else { return }

        let current = pairing.manualEndpoint ?? pairing.lastEndpoint ?? ""
        guard let address = prompt(
            title: "Address of the other Mac",
            explanation: "For networks that block discovery. Empty to go back to automatic.",
            value: current,
            placeholder: "192.168.1.42",
            confirm: "Save") else { return }

        if address.isEmpty {
            editPairing(labelled: label) { $0.manualEndpoint = nil }
            return
        }
        // Reject it here rather than at the next connection attempt.
        do {
            _ = try LinkConnector.parseEndpoint(address, defaultPort: Config().port)
        } catch {
            notify("That address was not accepted", error.localizedDescription)
            return
        }
        editPairing(labelled: label) { $0.manualEndpoint = address }
        if isRunning { stopSession(); startSession() }
    }

    /// Pairs with another Mac over the network, with no code to type.
    ///
    /// Both people choose the same menu item on both Macs; whichever finds the other dials.
    /// A six-digit number appears on each, and both confirm. Either both Macs save the same
    /// key or neither saves anything — the failure that typing a code allows, where one side
    /// quietly ends up with a different key, cannot happen here.
    @objc private func pairNearby() {
        guard let identity = try? Identity.loadOrCreate() else { return }
        let config = (try? Config.load()) ?? Config()
        runPairing(NetworkPairingSession(identity: identity, link: config.link),
                   allowAddressFallback: true)
    }

    /// The modal half, shared by discovery and by dialling a known address.
    private func runPairing(_ session: NetworkPairingSession, allowAddressFallback: Bool) {
        // One address, not a list. Offering two and leaving the choice to the reader is how
        // "which one do I type?" happens; the cable is always the better answer when it
        // exists, so pick it.
        let addresses = NetworkAddress.localAddresses()
        let best = addresses.first(where: NetworkAddress.isLinkLocalIPv4) ?? addresses.first
        let isCable = best.map(NetworkAddress.isLinkLocalIPv4) ?? false

        NSApp.activate(ignoringOtherApps: true)
        let waiting = NSAlert()
        waiting.messageText = "Looking for the other Mac"
        waiting.informativeText =
            "Choose the same on the other Mac. Both will show six digits to compare."
            + (best.map { "\n\nThis Mac: \($0)" + (isCable ? " (cable)" : "") } ?? "")
        waiting.addButton(withTitle: "Cancel")
        if allowAddressFallback {
            waiting.addButton(withTitle: "Enter the other Mac's address…")
            // Not reachable for the first few seconds: finding each other is the normal path,
            // and offering an escape hatch before it has had a chance to work invites people
            // to take it.
            if let button = waiting.buttons.last {
                button.isEnabled = false
                Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
                    button.isEnabled = true
                }
            }
        }

        // The alert is modal, so progress has to arrive as a dismissal rather than an update.
        let result = Box<NetworkPairingSession.Progress?>(nil)
        session.onProgress = { progress in
            switch progress {
            case .waiting, .found:
                break
            case .verify, .done, .failed:
                result.value = progress
                NSApp.abortModal()
            }
        }
        session.start()

        let response = waiting.runModal()
        guard let outcome = result.value else {
            session.cancel()
            if allowAddressFallback, response == .alertSecondButtonReturn {
                pairNearbyByAddress()
            }
            return
        }

        guard case let .verify(digits, peerName) = outcome else {
            if case let .failed(reason) = outcome { notify("Pairing failed", reason) }
            session.cancel()
            return
        }

        let compare = NSAlert()
        compare.messageText = digits
        compare.informativeText = "Does \(peerName) show the same number? Confirm on both."
        compare.addButton(withTitle: "Yes, they match")
        compare.addButton(withTitle: "No")

        let finish = Box<NetworkPairingSession.Progress?>(nil)
        session.onProgress = { progress in
            switch progress {
            case .done, .failed:
                finish.value = progress
                NSApp.abortModal()
            default:
                break
            }
        }

        guard compare.runModal() == .alertFirstButtonReturn else {
            session.confirm(false)
            return
        }
        session.confirm(true)

        // Wait for the other Mac to confirm too.
        let patience = NSAlert()
        patience.messageText = "Waiting for \(peerName)"
        patience.informativeText = "Confirm the number over there."
        patience.addButton(withTitle: "Cancel")
        if finish.value == nil {
            if patience.runModal() == .alertFirstButtonReturn, finish.value == nil {
                session.cancel()
                return
            }
        }

        switch finish.value {
        case let .done(result):
            save(result)
        case let .failed(reason):
            notify("Pairing failed", reason)
        default:
            notify("Pairing did not finish", "The other Mac did not confirm.")
        }
    }

    /// Same exchange, but dialling an address instead of waiting to discover one.
    ///
    /// This is the whole reason a typed code existed, and it is a much smaller thing to ask
    /// for: an address is visible in the other Mac's own menu, and getting it wrong fails
    /// immediately instead of looking like a successful pairing that will not connect.
    @objc private func pairNearbyByAddress() {
        guard let address = prompt(
            title: "The other Mac's address",
            explanation: "Choose Connect to a nearby Mac over there; it shows its address.",
            value: "",
            placeholder: "192.168.1.42",
            confirm: "Connect"), !address.isEmpty else { return }

        guard let identity = try? Identity.loadOrCreate() else { return }
        let config = (try? Config.load()) ?? Config()
        runPairing(NetworkPairingSession(identity: identity, link: config.link,
                                         address: address),
                    allowAddressFallback: false)
    }

    private func save(_ outcome: NetworkPairing.Outcome) {
        do {
            var store = try SecretStore.load()
            // Replace rather than accumulate: a second pairing with the same Mac is only ever
            // a leftover from a failed attempt, and two of them make dialling ambiguous.
            store.pairings.removeAll { $0.peerName == outcome.peerName || !$0.isBound }
            var pairing = Pairing(psk: outcome.psk, label: outcome.peerName)
            pairing.peerName = outcome.peerName
            store.pairings.append(pairing)
            try store.save()
            restartForPairingChange()
            notify("Paired with \(outcome.peerName)",
                   "Set the other Mac to \(mode.opposite.shortTitle), then Start on both.")
        } catch {
            notify("Could not save the pairing", error.localizedDescription)
        }
        refresh()
    }

    @objc private func pairNewMac() {
        let code = PairingCode.generate()
        do {
            var store = try SecretStore.load()
            // Replace any pairing that has never been used. Generating a second code while
            // the first is still outstanding leaves two keys and no way to tell which one the
            // other Mac was given.
            store.pairings.removeAll { !$0.isBound }
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
        let key = ((try? SecretStore.load()) ?? SecretStore()).pairings.last
            .map { String($0.keyIDHex.prefix(8)) } ?? "?"
        restartForPairingChange()
        notify("Now the Mac that lends its screen",
               "Open its menu, choose Devices ▸ Enter the code from the other Mac, and type "
               + "this in. Then press Start on both.\n\n"
               + "Both Macs should then show key \(key) under Devices. If they do, the pairing "
               + "matched. Until they actually connect, each shows the other as “not connected "
               + "yet” — neither can know the other's name before they have spoken.")
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
            store.pairings.removeAll { !$0.isBound }
            store.pairings.append(Pairing(psk: code.psk, label: Self.freshLabel(in: store)))
            try store.save()
            let key = String((store.pairings.last?.keyIDHex ?? "").prefix(8))
            restartForPairingChange()
            notify("Paired — key \(key)",
                   "Check the other Mac shows the same key under Devices; if it does, the "
                   + "code was typed correctly.\n\nThis Mac is set to: \(mode.title). The "
                   + "other must be set to the opposite. Then press Start on both.")
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
        confirm.informativeText = "You will need to pair the two Macs again."
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

        submenu.addItem(disabled("The other Mac is to my"))
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
        submenu.addItem(disabled("If the screens differ in size"))
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
        submenu.addItem(action("Show…", #selector(showArrangement)))
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
            notify("Clipboard sharing on", "Turn it on over there too.")
        }
        // The setting is read when a session starts, so an existing one has to be restarted.
        if isRunning {
            stopSession()
            startSession()
        }
        refresh()
    }

    @objc private func selectLink(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        applyConfig { $0.preferredLink = raw }
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

    @objc private func troubleshoot() {
        guard let executable = Bundle.main.executableURL else { return }
        let task = Process()
        task.executableURL = executable
        task.arguments = ["troubleshoot"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        var report: String
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            report = String(data: data, encoding: .utf8) ?? ""
            // The child writes for a terminal; strip the colour codes rather than show them.
            report = report.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "",
                                                 options: .regularExpression)
        } catch {
            report = "Could not run the check: \(error.localizedDescription)"
        }

        let alert = NSAlert()
        alert.messageText = "Why it is not connecting"
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        text.string = report
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isEditable = false
        text.drawsBackground = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
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
                "Already running here (pid \(other.pid)). Two at once makes the pointer lag."
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
        // Stop by process id, from the state file, rather than only the child this menu bar
        // happens to be holding a handle to. After the menu bar is relaunched — or after a
        // session is taken over — that handle is nil while the session is very much still
        // running, and Stop silently did nothing.
        var pids: [Int32] = []
        if let session, session.isRunning { pids.append(session.processIdentifier) }
        for role in [RuntimeState.Role.sharing, .listening] {
            if let state = RuntimeState.load(role), state.isLive, !pids.contains(state.pid) {
                pids.append(state.pid)
            }
        }

        // SIGINT rather than terminate(): the session handles it, which means it gives this
        // Mac its pointer back and un-hides the cursor on the way out.
        for pid in pids { kill(pid, SIGINT) }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let stillUp = pids.filter { kill($0, 0) == 0 }
            if stillUp.isEmpty { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        session = nil

        // A session started by the login item is not our child, so ask launchd too.
        try? LaunchAgent.stop()
        refresh()
    }

    private func notify(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
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
