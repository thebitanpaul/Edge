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
            menu.addItem(action("Why is it not connecting?…", #selector(troubleshoot)))
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

        let linkItem = NSMenuItem(title: "Connect over", action: nil, keyEquivalent: "")
        let linkMenu = NSMenu()
        for choice in LinkPreference.allCases {
            let entry = NSMenuItem(title: choice.title, action: #selector(selectLink(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.state = config.link == choice ? .on : .off
            entry.representedObject = choice.rawValue
            linkMenu.addItem(entry)
        }
        linkMenu.addItem(.separator())
        linkMenu.addItem(disabled("A USB-C or Thunderbolt cable between the"))
        linkMenu.addItem(disabled("two Macs is far quicker than Wi-Fi"))
        linkItem.submenu = linkMenu
        menu.addItem(linkItem)

        let login = action("Start at login", #selector(toggleLoginItem))
        login.state = LaunchAgent.installedRole != nil ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action("Why is it not connecting?…", #selector(troubleshoot)))
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
            "The two Macs need to share one secret, and none of this affects which Mac shares "
            + "its keyboard — you have just chosen that separately.\n\n"
            + "Pairing over the network is the reliable way: choose it on both Macs, compare "
            + "the six digits they show, and neither can end up with a different key. A typed "
            + "code works too, and is there for when the two Macs cannot see each other."
        pairAlert.addButton(withTitle: "Pair over the network")
        pairAlert.addButton(withTitle: "Use a code instead")
        pairAlert.addButton(withTitle: "Later")

        switch pairAlert.runModal() {
        case .alertFirstButtonReturn: pairNearby()
        case .alertSecondButtonReturn: pairNewMac()
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
                let connected = lastKnownState?.connected == true
                    && lastKnownState?.peerName == pairing.peerName
                let entry = NSMenuItem(title: displayName(for: pairing), action: nil,
                                       keyEquivalent: "")
                entry.state = connected ? .on : .off
                entry.submenu = detailMenu(for: pairing)
                submenu.addItem(entry)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(action("Pair with a nearby Mac…", #selector(pairNearby)))
        submenu.addItem(disabled("…choose this on both Macs, no code needed"))
        submenu.addItem(.separator())
        submenu.addItem(action("Show a pairing code…", #selector(pairNewMac)))
        submenu.addItem(action("Enter a pairing code…", #selector(enterPairingCode)))
        item.submenu = submenu
        return item
    }

    /// What to call a pairing in the menu.
    ///
    /// Both Macs invent the same local name for a new pairing, so two machines each showed
    /// "Mac 1" and neither said anything about the other. Until a handshake reveals who is on
    /// the far end there is genuinely nothing to show, so say that rather than showing a name
    /// that looks like an answer.
    private func displayName(for pairing: Pairing) -> String {
        if let peer = pairing.peerName, !peer.isEmpty { return peer }
        if !pairing.hasGeneratedLabel { return pairing.label }
        return "\(pairing.label) — not connected yet"
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
                                explanation: "Only a name for this list on this Mac. It does "
                                    + "not change anything on the other machine.",
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
            explanation: "Needed when Bonjour discovery is blocked, which is common on managed "
                + "networks. Find it on the other Mac under Devices, or from `continuous doctor`. "
                + "Leave it empty to go back to discovery.",
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
        let session = NetworkPairingSession(identity: identity, link: config.link)

        let waiting = NSAlert()
        waiting.messageText = "Looking for the other Mac"
        waiting.informativeText =
            "Choose “Pair with a nearby Mac” on the other Mac too, within the next two minutes.\n\n"
            + "They will each show the same six-digit number for you to compare."
        waiting.addButton(withTitle: "Cancel")

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
            _ = response
            return
        }

        guard case let .verify(digits, peerName) = outcome else {
            if case let .failed(reason) = outcome { notify("Pairing failed", reason) }
            session.cancel()
            return
        }

        let compare = NSAlert()
        compare.messageText = digits
        compare.informativeText =
            "Does \(peerName) show the same six digits?\n\n"
            + "Confirm on both Macs. If the numbers differ, something is between them — say "
            + "No and try again."
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
        patience.informativeText = "Confirm the same number over there."
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
                   "Both Macs now hold the same key — no code was typed, so they cannot differ."
                   + "\n\nSet this Mac to \(mode.title) and the other to the opposite, then "
                   + "press Start on both.")
        } catch {
            notify("Could not save the pairing", error.localizedDescription)
        }
        refresh()
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
        let key = ((try? SecretStore.load()) ?? SecretStore()).pairings.last
            .map { String($0.keyIDHex.prefix(8)) } ?? "?"
        restartForPairingChange()
        notify("Now the other Mac",
               "Enter that code there, set it to the opposite role, and press Start on both.\n\n"
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
                "A Continuous session is already running on this Mac (pid \(other.pid), "
                + "\(other.role.rawValue)) — probably started from a terminal, or a login item."
                + "\n\nOne Mac runs one session. Two means two event taps and doubled traffic, "
                + "which feels like a laggy pointer and a cursor that will not stay hidden."
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
