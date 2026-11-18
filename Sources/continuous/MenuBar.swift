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
    private var arrangementWindow: ArrangementWindowController?
    private var pairingWindow: PairingWindowController?
    /// Double optional on purpose: "not yet looked" is different from "looked, nothing
    /// wrong", and only the transition into a problem is worth announcing.
    private var lastAnnouncedLinkProblem: String??
    private var blinkOn = true
    /// Pending retry of the secondary's listener, cancelled whenever one starts by any route.
    private var autoStartWork: DispatchWorkItem?

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
        // Seed it, so an existing problem at launch is reported once the session is actually
        // running rather than the instant the menu appears.
        lastAnnouncedLinkProblem = .some(linkProblem)
        redrawIcon()

        // Faster than a human notices a state change, slower than anything that matters.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
        autoStartIfSecondary()
    }

    // MARK: - One Mac drives

    /// The secondary makes itself ready without being asked.
    ///
    /// Pressing Start on two Macs to get one pointer was always a thing to remember rather
    /// than a decision: the secondary has nothing to decide — it waits, and until the primary
    /// dials there is nothing for it to do. Remote *start* is not possible in the other
    /// direction, because a Mac that has stopped has nothing left listening to be told; so
    /// instead the secondary never stops on its own, and the primary's Start and Stop are the
    /// only two buttons that matter. Stopping the primary closes the link, which the secondary
    /// sees at once and goes back to waiting.
    ///
    /// Stopping the secondary by hand is still honoured — it is remembered, and nothing here
    /// starts it again until Start is pressed there.
    private func autoStartIfSecondary() {
        autoStartWork?.cancel()
        autoStartWork = nil
        guard mode == .client, !stoppedByHand, !isRunning else { return }
        guard !((try? SecretStore.load()) ?? SecretStore()).pairings.isEmpty else { return }
        startSession()
    }

    /// Tries again shortly. Used when the listener exits on its own — a managed Mac going to
    /// sleep, say — so it comes back without anyone walking over to it.
    private func scheduleAutoStart(after delay: TimeInterval) {
        guard mode == .client, !stoppedByHand else { return }
        autoStartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autoStartIfSecondary() }
        autoStartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var stoppedByHand: Bool {
        get { UserDefaults.standard.bool(forKey: "stoppedByHand") }
        set { UserDefaults.standard.set(newValue, forKey: "stoppedByHand") }
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

    /// Searching, as opposed to merely waiting.
    ///
    /// Only the primary searches: it is the one dialling, and a blinking icon says "something
    /// is happening, give it a moment". The secondary does not dial, so for it the same state
    /// is simply *ready*, and blinking at it for hours was the icon crying wolf.
    private var isSearching: Bool {
        mode == .host && isRunning && lastKnownState?.connected != true
    }

    private func refresh() {
        lastKnownState = currentState
        updateBlinking()
        announceLinkProblemIfNeeded()

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

        if store.pairings.isEmpty {
            menu.addItem(disabled("Not set up"))
            menu.addItem(action("Set up", #selector(runSetup)))
            menu.addItem(.separator())
            menu.addItem(action("Quit", #selector(quit)))
            return
        }

        // Status: role first, because everything else in this menu depends on it.
        if !isRunning {
            menu.addItem(disabled("Stopped · \(mode.shortTitle)"))
            // Worth spelling out on the secondary: the primary has no way to say so, and a
            // Mac that will not connect is the only symptom.
            if mode == .client {
                menu.addItem(disabled("The primary cannot reach this Mac while it is stopped"))
            }
        } else if let state, state.connected {
            let peer = state.peerName ?? "the other Mac"
            menu.addItem(disabled(mode == .host && state.pointerIsRemote == true
                                  ? "Pointer on \(peer)"
                                  : "\(mode.shortTitle) · connected to \(peer)"))
            // Which link, and how fast. A connection that succeeds over the slow link is the
            // commonest surprise here, and without naming it a dragging pointer reads as a
            // bug in the forwarding rather than as Wi-Fi.
            var detail: [String] = []
            if let via = state.via { detail.append(linkName(via)) }
            if let rtt = state.rttMillis { detail.append(String(format: "%.0f ms", rtt)) }
            if state.clipboardActive { detail.append("clipboard") }
            if !detail.isEmpty { menu.addItem(disabled(detail.joined(separator: " · "))) }
        } else if mode == .client {
            // The secondary has nothing to do until the primary dials, and nothing it can do
            // to hurry that along. "Ready" is the truth; "connecting" was not.
            menu.addItem(disabled("Secondary · ready"))
            menu.addItem(disabled("Start it on the primary Mac"))
        } else {
            menu.addItem(disabled("Primary · connecting"))
            menu.addItem(disabled(waitingHint))
        }

        // A link that cannot exist is worth saying out loud rather than retrying in silence.
        if let problem = linkProblem {
            menu.addItem(.separator())
            menu.addItem(disabled(problem))
            menu.addItem(action("Use Wi-Fi instead", #selector(switchToWiFi)))
        }

        menu.addItem(.separator())
        menu.addItem(action(isRunning ? "Stop" : "Start", #selector(toggleRunning)))

        menu.addItem(.separator())
        menu.addItem(devicesMenuItem())

        // Only the primary has any use for these. The arrangement decides where *its* pointer
        // goes, and the link preference governs dialling out, which only it does. Showing
        // them on the secondary invited changes that silently did nothing.
        if mode == .host {
            menu.addItem(arrangementMenuItem())
            menu.addItem(linkMenuItem())
        }

        let config = (try? Config.load()) ?? Config()
        menu.addItem(.separator())
        let clipboard = action("Share clipboard", #selector(toggleClipboard))
        clipboard.state = config.clipboardSharing ? .on : .off
        menu.addItem(clipboard)

        let login = action("Start at login", #selector(toggleLoginItem))
        login.state = LaunchAgent.installedRole != nil ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action("Reconfigure", #selector(runSetup)))
        menu.addItem(helpMenuItem())
        menu.addItem(action("Quit", #selector(quit)))
    }

    private func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(action("Open log", #selector(openLog)))
        submenu.addItem(action("Report an issue", #selector(reportIssue)))
        submenu.addItem(.separator())
        submenu.addItem(disabled(Runtime.shortVersion))
        item.submenu = submenu
        return item
    }

    /// "cable, 169.254.3.2" → "Cable". Enough to answer "why is this slow?" and no more.
    private func linkName(_ via: String) -> String {
        let lower = via.lowercased()
        if lower.hasPrefix("cable") { return "Cable" }
        if lower.hasPrefix("wi-fi") { return "Wi-Fi" }
        if lower.hasPrefix("bonjour") || lower.hasPrefix("hostname") { return "Network" }
        return "Network"
    }

    /// Opens a mail message to the address below, pre-filled with what a bug report needs.
    ///
    /// Falls back to showing the address when nothing on this Mac handles mail — a work Mac
    /// with no mail client is common, and silently doing nothing is the worst outcome.
    private static let supportAddress = "thephiuture@gmail.com"

    @objc private func reportIssue() {
        DispatchQueue.main.async { [weak self] in self?.performReportIssue() }
    }

    private func performReportIssue() {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let body = """
            What happened:


            What you expected:


            ---
            Continuous \(Runtime.shortVersion)
            \(os)
            Role: \(mode.shortTitle)
            """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Continuous \(Runtime.shortVersion) — issue"),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url, NSWorkspace.shared.open(url) { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "No mail app is set up"
        alert.informativeText = "Send the report to \(Self.supportAddress)."
        alert.addButton(withTitle: "Copy address")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.supportAddress, forType: .string)
        }
    }

    /// A link preference that cannot currently be satisfied, or nil.
    ///
    /// Unplug the cable with the preference set to cable and the session retries for ever
    /// against something that is not there. Nothing in the interface said so, which leaves
    /// someone watching a Mac that will not connect with no idea why.
    private var linkProblem: String? {
        guard mode == .host else { return nil }
        let config = (try? Config.load()) ?? Config()
        let addresses = NetworkAddress.localAddresses()
        switch config.link {
        case .cable:
            return addresses.contains(where: NetworkAddress.isLinkLocalIPv4)
                ? nil : "Set to cable, but no cable is connected"
        case .wifi:
            return addresses.contains(where: { !NetworkAddress.isLinkLocalIPv4($0) })
                ? nil : "Set to Wi-Fi, but this Mac is not on a network"
        case .auto:
            return addresses.isEmpty ? "This Mac is not on any network" : nil
        }
    }

    /// Says it once, when it starts being true, rather than every half second.
    private func announceLinkProblemIfNeeded() {
        let problem = linkProblem
        guard problem != lastAnnouncedLinkProblem else { return }
        lastAnnouncedLinkProblem = problem
        guard let problem, isRunning else { return }

        stopSession()
        notify(problem, "Stopped. Choose a link that exists, or reconnect the cable.")
        refresh()
    }

    @objc private func switchToWiFi() {
        applyConfig { $0.preferredLink = LinkPreference.auto.rawValue }
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
        // Deferred by one turn of the run loop so menu tracking ends first; a window opened
        // while the menu is still tracking never becomes key, and its text fields silently
        // ignore every keystroke.
        DispatchQueue.main.async { [weak self] in self?.performSetup() }
    }

    private func performSetup() {
        let alert = NSAlert()
        NSApp.activate(ignoringOtherApps: true)
        alert.messageText = "Which Mac is this?"
        alert.informativeText =
            "Set the other Mac to the opposite.\n\n"
            + "Both Macs need the same Wi-Fi network to find each other."
        alert.addButton(withTitle: "Primary — I use this keyboard")
        alert.addButton(withTitle: "Secondary — controlled by the other")
        alert.addButton(withTitle: "Cancel")

        let answer = alert.runModal()
        guard answer != .alertThirdButtonReturn else { return }
        let chosen: Mode = answer == .alertFirstButtonReturn ? .host : .client
        let changed = chosen != mode

        // Stop first, always. Changing roles while a session runs leaves it dialling with the
        // old one, which is why switching appeared to half-work: the connection came back
        // wrong rather than not at all.
        stopSession()
        setMode(chosen, restart: false)

        let store = (try? SecretStore.load()) ?? SecretStore()
        if store.pairings.isEmpty {
            performPairNearby()
            return
        }

        guard changed else {
            notify("This Mac is \(chosen.shortTitle)", startingInstruction(for: chosen))
            autoStartIfSecondary()
            refresh()
            return
        }

        // A role change throws the screen arrangement away, and it has to: it described
        // where the *other* Mac sat relative to this one, and that sentence is now about a
        // different pair of screens. Saying so here rather than letting it be discovered the
        // first time the pointer refuses to cross.
        if chosen == .host {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "This Mac is now Primary"
            alert.informativeText =
                "Set the other Mac to Secondary.\n\n"
                + "The screen arrangement was reset — say where the other Mac's screen sits "
                + "before the pointer can cross to it."
            alert.addButton(withTitle: "Arrange screens")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                performShowArrangement()
            }
        } else {
            notify("This Mac is now Secondary",
                   "Set the other Mac to Primary and arrange the screens there. "
                   + "This Mac stays ready on its own.")
            autoStartIfSecondary()
        }
        refresh()
    }

    /// What to press, and where, once the roles are settled.
    private func startingInstruction(for chosen: Mode) -> String {
        chosen == .host ? "Press Start here. The other Mac stays ready on its own."
                        : "This Mac stays ready on its own — press Start on the primary."
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
        // Every pairing, connected or not. Hiding the unconnected ones was meant to stop a
        // generated code looking like a paired Mac — but pairing over the network learns the
        // other Mac's name as part of the exchange, so there is a real Mac to name from the
        // moment it succeeds, and hiding it made a successful pairing look like a failed one.
        if store.pairings.isEmpty {
            submenu.addItem(disabled("No Macs paired yet"))
        } else {
            for pairing in store.pairings {
                let connected = lastKnownState?.connected == true
                    && lastKnownState?.peerName == pairing.peerName
                let name = pairing.peerName ?? pairing.label
                let entry = NSMenuItem(title: connected || pairing.isBound ? name
                                                                          : "\(name) — not connected yet",
                                       action: nil, keyEquivalent: "")
                entry.state = connected ? .on : .off
                entry.submenu = detailMenu(for: pairing)
                submenu.addItem(entry)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(action("Connect to a nearby Mac", #selector(pairNearby)))
        submenu.addItem(disabled("Choose this on both Macs"))
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
        for (title, selector) in [("Rename", #selector(renameDevice(_:))),
                                  ("Set address", #selector(setDeviceAddress(_:))),
                                  ("Forget", #selector(forgetDevice(_:)))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            entry.representedObject = pairing.label
            detail.addItem(entry)
        }
        return detail
    }

    private func prompt(title: String, explanation: String, value: String,
                        placeholder: String, confirm: String) -> String? {
        InputPanel.ask(title: title, explanation: explanation, value: value,
                       placeholder: placeholder, confirm: confirm)
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
        let label = sender.representedObject as? String
        DispatchQueue.main.async { [weak self] in self?.performRename(label) }
    }

    private func performRename(_ label: String?) {
        guard let label else { return }
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
        let label = sender.representedObject as? String
        DispatchQueue.main.async { [weak self] in self?.performSetAddress(label) }
    }

    private func performSetAddress(_ label: String?) {
        guard let label else { return }
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
        // Deferred by one turn of the run loop so menu tracking ends first; a window opened
        // while the menu is still tracking never becomes key, and its text fields silently
        // ignore every keystroke.
        DispatchQueue.main.async { [weak self] in self?.performPairNearby() }
    }

    private func performPairNearby() {
        guard let identity = try? Identity.loadOrCreate() else { return }
        let config = (try? Config.load()) ?? Config()
        if pairingWindow == nil {
            let controller = PairingWindowController(identity: identity, link: config.link)
            controller.onPaired = { [weak self] outcome in
                self?.save(outcome)
                self?.pairingWindow = nil
            }
            pairingWindow = controller
        }
        pairingWindow?.present()
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
                   "Set the other Mac to \(mode.opposite.shortTitle). "
                   + startingInstruction(for: mode))
            autoStartIfSecondary()
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
        let label = sender.representedObject as? String
        DispatchQueue.main.async { [weak self] in self?.performForget(label) }
    }

    private func performForget(_ label: String?) {
        guard let label else { return }
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
        // Opens the window. Everything it offers lives there, so a submenu repeating it would
        // be a second place to change the same thing.
        let item = NSMenuItem(title: "Screen arrangement", action: #selector(showArrangement),
                              keyEquivalent: "")
        item.target = self
        return item
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
        // Deferred by one turn of the run loop so menu tracking ends first; a window opened
        // while the menu is still tracking never becomes key, and its text fields silently
        // ignore every keystroke.
        DispatchQueue.main.async { [weak self] in self?.performShowArrangement() }
    }

    private func performShowArrangement() {
        if arrangementWindow == nil {
            // Editable only on the primary: the arrangement decides where that Mac's pointer
            // goes, and the secondary has no say in it.
            let controller = ArrangementWindowController(editable: mode == .host)
            controller.onEdgeChanged = { [weak self] in
                guard let self, self.isRunning else { return }
                self.stopSession()
                self.startSession()
            }
            arrangementWindow = controller
        }
        arrangementWindow?.present()
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
        if isRunning {
            // Remembered, so the secondary's own Stop is not undone a moment later by the
            // thing that keeps it ready.
            stoppedByHand = true
            autoStartWork?.cancel()
            stopSession()
        } else {
            stoppedByHand = false
            startSession()
        }
    }

    private func setMode(_ chosen: Mode, restart: Bool) {
        guard chosen != mode else { return }
        stopSession()
        mode = chosen
        UserDefaults.standard.set(chosen.rawValue, forKey: "mode")

        // The arrangement described where the *other* Mac sat relative to this one. Swap the
        // roles and that sentence is about a different pair of screens, so keeping the old
        // answer is worse than having none: it looks configured and points the wrong way.
        var config = (try? Config.load()) ?? Config()
        config.remoteEdge = ScreenEdge.right.rawValue
        try? config.save()

        // Editability depends on the role, and the window caches it, so it has to go.
        arrangementWindow?.close()
        arrangementWindow = nil

        // A Stop pressed in the old role says nothing about the new one. Left set, it would
        // keep a Mac that has just become the secondary from making itself ready.
        stoppedByHand = false

        if restart { startSession() }
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
                    // The secondary is meant to stay ready, so a session that fell over comes
                    // back by itself rather than needing someone to walk over to that Mac.
                    if self.mode == .client && !self.stoppedByHand {
                        Log.warn("the listener exited (status \(finished.terminationStatus)); starting it again")
                        self.scheduleAutoStart(after: 3)
                    } else {
                        self.notify("Continuous stopped",
                                    "The session exited. Open the log from the menu to see why.")
                    }
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
