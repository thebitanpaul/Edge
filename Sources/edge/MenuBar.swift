import AppKit
import Foundation
import EdgeControlState
import EdgeCore
import WidgetKit

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
        /// "Primary" and "secondary" rather than "share" and "lend": you know which Mac you
        /// are sitting at long before you know what it will be doing for the other one.
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
    /// Last answer from the privacy database, and when it was asked. Asking is a round trip
    /// to another process, so it is not worth doing twice a second.
    private var permissionsWereGranted = true
    private var lastPermissionCheck = Date.distantPast
    /// What the Control Center control was last told to show, so it is only reloaded on change.
    private var lastPublishedControl: ControlState?
    /// Runs while the menu-bar icon is hidden, to bring it back if Control Center loses Edge.
    private var reachabilityTimer: Timer?
    /// Consecutive checks that did not find the switch. One is not enough to act on: macOS
    /// briefly reports nothing placed while Control Center reloads, and taking that at face
    /// value put the icon back every time Edge was turned on from the switch.
    private var missedPlacementChecks = 0
    /// The icon is hidden because that was chosen and the switch is there to stand in for it.
    private var hiddenByChoice = false
    /// One of Edge's controls is sitting in the menu bar itself. Edge's own icon steps aside
    /// for it, so there is never a second Edge icon up there.
    private var controlInMenuBar = false
    private var menuBarScanTimer: Timer?
    private let menuBarScanQueue = DispatchQueue(label: "app.edge.menubar-scan", qos: .utility)

    private var logURL: URL { Paths.supportDirectory.appendingPathComponent("session.log") }

    /// Where this app's preferences lived before it was called Edge.
    ///
    /// They are keyed on the bundle identifier, which the rename changed, so without this a
    /// Mac that was the secondary quietly comes back as the primary — and two primaries is
    /// precisely the configuration where neither one dials and nothing says why.
    private static let formerDefaults = UserDefaults(suiteName: "app.continuous.cli")

    override init() {
        let stored = (UserDefaults.standard.string(forKey: "mode")
                      ?? Self.formerDefaults?.string(forKey: "mode"))
            .flatMap(Mode.init(rawValue:))
        self.mode = stored ?? .host
        super.init()
        if UserDefaults.standard.string(forKey: "mode") == nil, let stored {
            UserDefaults.standard.set(stored.rawValue, forKey: "mode")
        }
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
        // Let the system fold this into other wakeups; nobody notices a quarter second here.
        refreshTimer?.tolerance = 0.25
        // Before anything reads it: an agent under the old name starts a bundle that no
        // longer exists, every login, with nothing in the interface to say so.
        LaunchAgent.removeFormerAgent()
        LoginItem.migrateFromLaunchAgent()
        // Hidden from the first frame when that is the choice, then confirmed. Shown and then
        // hidden a moment later read as a second icon appearing and vanishing.
        if prefersHiddenIcon && controlsAvailable { hiddenByChoice = true; applyIconVisibility() }
        applyMenuBarVisibility()
        startScanningMenuBar()
        permissionsWereGranted = missingPermissions.isEmpty
        // Anyone who already has a pairing has been through this; the flag is new, they are not.
        if !setupCompleted, !(((try? SecretStore.load()) ?? SecretStore()).pairings.isEmpty) {
            setupCompleted = true
        }
        refresh()
        // A control left showing "On" by a crash is corrected the moment the app is back.
        publishControlState()

        // Asked for at launch rather than at the first attempt to use them. Being told what
        // an app needs before it needs it is the difference between a decision and an
        // interruption.
        //
        // Deferred a turn: this runs before NSApplication.run(), and an alert raised from
        // there spins a modal loop inside a loop that has not started yet.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.ensurePermissions() {
                self.autoStartIfSecondary()
                self.autoStartIfStartingAtLogin()
            }
        }
    }

    // MARK: - Permissions

    /// What macOS has to be told to allow, for the role this Mac is playing.
    ///
    /// The secondary only ever *posts* events, which is Accessibility. The primary also has
    /// to *read* this keyboard, and that is a second, separate grant — which is why a Mac can
    /// move a pointer perfectly and then do nothing at all when you type.
    private struct MissingPermission {
        let name: String
        let why: String
        let settingsURL: String
    }

    private var missingPermissions: [MissingPermission] {
        var missing: [MissingPermission] = []
        if !Permissions.accessibility().isGranted {
            missing.append(MissingPermission(
                name: "Accessibility",
                why: mode == .host ? "to let the pointer cross to the other Mac"
                                   : "to move this Mac's pointer and type on it",
                settingsURL: Permissions.accessibilitySettingsURL))
        }
        if mode == .host, !Permissions.inputMonitoring().isGranted {
            missing.append(MissingPermission(
                name: "Input Monitoring",
                why: "to read this keyboard and send it across",
                settingsURL: Permissions.inputMonitoringSettingsURL))
        }
        return missing
    }

    /// True when everything needed is granted. Otherwise it says so and opens the right pane.
    ///
    /// Called before anything tries to start. Without it the session process exits a second
    /// later with the reason in a log file, which is not somewhere anyone looks when an app
    /// simply does nothing.
    @discardableResult
    private func ensurePermissions(explaining: Bool = true) -> Bool {
        let missing = missingPermissions
        guard !missing.isEmpty else { return true }
        guard explaining else { return false }

        // The system's own prompt first, when macOS has not yet made up its mind — it is the
        // one that can grant without a trip through Settings.
        _ = Permissions.accessibility(prompt: true)
        if mode == .host, Permissions.inputMonitoring() == .undetermined {
            Permissions.requestInputMonitoring()
        }
        if missingPermissions.isEmpty { return true }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = missing.count == 1
            ? "Edge needs \(missing[0].name)"
            : "Edge needs two permissions"
        alert.informativeText =
            missing.map { "\($0.name) — \($0.why)" }.joined(separator: "\n")
            + "\n\nEdge only talks to the Mac you paired. Its location is copied, in case "
            + "System Settings asks you to add it with +."
        for item in missing { alert.addButton(withTitle: "Open \(item.name)") }
        alert.addButton(withTitle: "Later")

        let answer = alert.runModal()
        let index = answer.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index >= 0, index < missing.count {
            Permissions.openSettings(missing[index].settingsURL)
            if Permissions.isRunningInsideAppBundle {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Bundle.main.bundlePath, forType: .string)
            }
        }
        return false
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

    /// The primary picks up where it was, when Edge is set to start at login.
    ///
    /// Start at login used to start the session itself, headless; now it opens the app, and an
    /// app that opened at login and then sat there stopped would be the switch quietly doing
    /// less than it did. A Stop pressed by hand is still honoured, so this only ever resumes a
    /// primary that was left running.
    private func autoStartIfStartingAtLogin() {
        guard mode == .host, LoginItem.isEnabled, setupCompleted,
              !stoppedByHand, !isRunning else { return }
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

    /// Whether this Mac has been through setup and run at least once.
    ///
    /// Setting up is a sequence with one right answer at each step, so everything that is a
    /// *preference* rather than a step stays out of the menu until it is over. Which link to
    /// use is the clearest example: it has a sensible default, and offering it to someone who
    /// has not yet connected once is offering them a way to get it wrong.
    private var setupCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: "setupCompleted") }
        set { UserDefaults.standard.set(newValue, forKey: "setupCompleted") }
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
        // A session asking for a role swap: see `switchRole`.
        if let note = RoleSwitchNote.take() {
            applyRoleSwitch(note)
            return
        }
        lastKnownState = currentState
        updateBlinking()
        announceLinkProblemIfNeeded()
        checkPermissionsOccasionally()

        // Only redraw when it would differ. Touching an NSStatusItem button makes AppKit
        // reconsider the cursor, and doing that twice a second un-hid the cursor the session
        // was holding hidden — which is how the menu-bar front end left a visible pointer
        // behind on a screen nobody was using, and the terminal did not.
        let signature = iconSignature
        if signature != lastIconSignature {
            lastIconSignature = signature
            redrawIcon()
            publishControlState()
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
            blinkTimer?.tolerance = 0.15
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
            description = "Edge — stopped"
        } else if state?.connected != true {
            symbol = "cursorarrow"
            description = "Edge — connecting"
        } else if state?.pointerIsRemote == true {
            symbol = "arrow.right.to.line"
            description = "Edge — pointer is on the other Mac"
        } else {
            symbol = "cursorarrow.rays"
            description = "Edge — connected"
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

        // Above everything else, including "Not set up": nothing below can work without it,
        // and a Mac that has not been set up yet is exactly where someone meets this first.
        func addPermissionItems() {
            for item in missingPermissions {
                menu.addItem(.separator())
                let grant = action("Grant \(item.name)", #selector(grantPermission(_:)))
                grant.representedObject = item.settingsURL
                menu.addItem(grant)
            }
        }

        if store.pairings.isEmpty {
            menu.addItem(action("Set up", #selector(runSetup)))
            addPermissionItems()
            menu.addItem(.separator())
            menu.addItem(action("Quit Edge", #selector(quit)))
            return
        }

        // Status: role first, because everything else in this menu depends on it.
        if !isRunning {
            menu.addItem(disabled("Stopped · \(mode.shortTitle)"))
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
            menu.addItem(disabled("Secondary · waiting for the primary"))
        } else {
            menu.addItem(disabled("Primary · connecting"))
            menu.addItem(disabled(waitingHint))
        }

        addPermissionItems()

        // A link that cannot exist is worth saying out loud rather than retrying in silence.
        if let problem = linkProblem {
            menu.addItem(.separator())
            menu.addItem(disabled(problem))
            if ((try? Config.load()) ?? Config()).link != .auto {
                menu.addItem(action("Use whichever connects", #selector(useAnyLink)))
            }
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
            if setupCompleted { menu.addItem(linkMenuItem()) }
        }

        let config = (try? Config.load()) ?? Config()
        menu.addItem(.separator())
        let clipboard = action("Share clipboard", #selector(toggleClipboard))
        clipboard.state = config.clipboardSharing ? .on : .off
        menu.addItem(clipboard)

        let files = action("Carry dragged files", #selector(toggleFiles))
        files.state = config.fileSharing ? .on : .off
        menu.addItem(files)

        // Read from the system every time the menu is built, not remembered: removing Edge
        // under Login Items in System Settings has to un-tick this too.
        let needsApproval = LoginItem.needsApproval
        let login = action(needsApproval ? "Start at login — switched off in System Settings"
                                         : "Start at login",
                           #selector(toggleLoginItem))
        login.state = LoginItem.isEnabled ? .on : (needsApproval ? .mixed : .off)
        menu.addItem(login)

        if controlsAvailable {
            let icon = action("Show in menu bar", #selector(toggleMenuBarIcon))
            icon.state = prefersHiddenIcon ? .off : .on
            menu.addItem(icon)
        }

        menu.addItem(.separator())
        menu.addItem(action("Switch to \(mode.opposite.shortTitle)", #selector(switchRole)))
        menu.addItem(helpMenuItem())
        menu.addItem(action("Quit Edge", #selector(quit)))
    }

    private func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(action("Open log", #selector(openLog)))
        submenu.addItem(action("Report an issue", #selector(reportIssue)))
        submenu.addItem(.separator())
        submenu.addItem(disabled("Version \(Runtime.shortVersion)"))
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
            Edge \(Runtime.shortVersion)
            \(os)
            Role: \(mode.shortTitle)
            """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Edge \(Runtime.shortVersion) — issue"),
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
        let config = (try? Config.load()) ?? Config()
        notify(problem, config.link == .auto
               ? "Edge stopped. Choose Start once this Mac is on a network."
               : "Edge stopped. \(config.link == .cable ? "Connect the cable" : "Join a network"), "
                 + "or choose Use whichever connects.")
        refresh()
    }

    /// Notices a permission being taken away, and being given back.
    ///
    /// Revoking one does not stop the app politely: the event tap goes dead and this Mac
    /// quietly stops being able to do the one thing it is for. Noticing within a couple of
    /// seconds and saying so is better than leaving someone to work out why.
    private func checkPermissionsOccasionally() {
        guard Date().timeIntervalSince(lastPermissionCheck) > 2 else { return }
        lastPermissionCheck = Date()

        let granted = missingPermissions.isEmpty
        defer { permissionsWereGranted = granted }
        guard granted != permissionsWereGranted else { return }

        if granted {
            autoStartIfSecondary()
        } else {
            stopSession()
            ensurePermissions()
        }
    }

    @objc private func grantPermission(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        Permissions.openSettings(url)
    }

    @objc private func useAnyLink() {
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
        alert.informativeText = "Primary is the Mac whose keyboard and mouse you use. "
            + "The other one is Secondary."
        alert.addButton(withTitle: "Primary")
        alert.addButton(withTitle: "Secondary")
        alert.addButton(withTitle: "Cancel")

        let answer = alert.runModal()
        guard answer != .alertThirdButtonReturn else { return }
        let chosen: Mode = answer == .alertFirstButtonReturn ? .host : .client

        // Stop first, always. Changing roles while a session runs leaves it dialling with the
        // old one, which is why switching appeared to half-work: the connection came back
        // wrong rather than not at all.
        stopSession()
        setMode(chosen, restart: false)

        if ((try? SecretStore.load()) ?? SecretStore()).pairings.isEmpty {
            // Whichever connects. Nothing is known yet about what this desk has, and a
            // preference chosen before the first connection is a guess that can only fail.
            applyConfig { $0.preferredLink = LinkPreference.auto.rawValue }
            performPairNearby()
            return
        }
        autoStartIfSecondary()
        refresh()
    }

    // MARK: Switching roles

    /// Pending fallback for a switch the other Mac has been asked to join.
    private var pendingRoleSwitch: DispatchWorkItem?

    /// Swaps the two Macs' roles, both at once when they are connected.
    ///
    /// Only the session holds the link, so it is asked with a signal. Whichever Mac this is,
    /// the primary drives: it tells the other Mac to take over, with the arrangement already
    /// mirrored, and each session leaves a note this app acts on (see `RoleSwitchNote`). If
    /// nothing comes back — the other Mac is on an older build, or the link has just
    /// dropped — this Mac switches on its own and says what is left to do.
    @objc private func switchRole() {
        let becomePrimary = mode == .client
        guard let state = currentState, state.connected else {
            applyRoleSwitch(RoleSwitchNote(becomePrimary: becomePrimary, otherMacFollows: false))
            return
        }
        kill(state.pid, SIGUSR1)
        let fallback = DispatchWorkItem { [weak self] in
            self?.applyRoleSwitch(RoleSwitchNote(becomePrimary: becomePrimary, otherMacFollows: false))
        }
        pendingRoleSwitch?.cancel()
        pendingRoleSwitch = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: fallback)
    }

    private func applyRoleSwitch(_ note: RoleSwitchNote) {
        pendingRoleSwitch?.cancel()
        pendingRoleSwitch = nil
        let chosen: Mode = note.becomePrimary ? .host : .client
        guard chosen != mode else { return }
        setMode(chosen, restart: false)

        if note.becomePrimary {
            // Where the other Mac sits, as it described this one from its side.
            if let edge = note.edge.flatMap(ScreenEdge.parse) {
                var config = (try? Config.load()) ?? Config()
                config.remoteEdge = edge.rawValue
                if let alignment = note.alignment.flatMap(ScreenAlignment.parse) {
                    config.remoteAlignment = alignment.rawValue
                }
                try? config.save()
            }
            performShowArrangement(headline: note.otherMacFollows
                ? "Now Primary. Check the arrangement, then press Start."
                : "Now Primary. Switch the other Mac to Secondary, then press Start.")
        } else {
            autoStartIfSecondary()
            if !note.otherMacFollows {
                notify("Now Secondary", "Switch the other Mac to Primary too.")
            }
        }
        refresh()
    }

    /// A short line naming the likeliest reason nothing has connected yet.
    ///
    /// The commonest by far is both Macs set to the same role, and because neither one dials
    /// in that case there is nothing in any log to notice.
    private var waitingHint: String {
        "The other Mac must be \(mode.opposite.shortTitle)"
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
        submenu.addItem(action("Pair a Mac", #selector(pairNearby)))
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

        guard let name = prompt(title: "Rename \(pairing.peerName ?? pairing.label)",
                                explanation: "A name for this list.",
                                value: pairing.peerName ?? pairing.label,
                                placeholder: "Work Mac",
                                confirm: "Rename"), !name.isEmpty else { return }

        guard !store.pairings.contains(where: { $0.label != label && $0.label == name }) else {
            notify("That name is taken", "Another Mac is already called “\(name)”.")
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
            explanation: "Only needed on networks that block discovery. Leave it empty to find the Mac automatically.",
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
            pairing.peerDisplays = outcome.peerDisplays
            store.pairings.append(pairing)
            try store.save()
            restartForPairingChange()
            // Straight on to the next step rather than back to a menu. The primary says
            // where the other Mac sits and presses Start; the secondary has nothing to decide
            // and has already made itself ready.
            if mode == .host {
                // One turn of the run loop, so the pairing window is fully gone first.
                let headline = "Paired with \(outcome.peerName). Check the arrangement, then press Start."
                DispatchQueue.main.async { [weak self] in self?.performShowArrangement(headline: headline) }
            } else {
                notify("Paired with \(outcome.peerName)", "Choose Start on the primary.")
                autoStartIfSecondary()
            }
        } catch {
            notify("Could not save the pairing", error.localizedDescription)
        }
        refresh()
        publishControlState()
    }

    @objc private func forgetDevice(_ sender: NSMenuItem) {
        let label = sender.representedObject as? String
        DispatchQueue.main.async { [weak self] in self?.performForget(label) }
    }

    private func performForget(_ label: String?) {
        guard let label else { return }
        let confirm = NSAlert()
        confirm.messageText = "Forget “\(label)”?"
        confirm.informativeText = "You'll need to pair again to use it."
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
        publishControlState()
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

    private func performShowArrangement(headline: String? = nil) {
        if arrangementWindow == nil {
            // Editable only on the primary: the arrangement decides where that Mac's pointer
            // goes, and the secondary has no say in it.
            let controller = ArrangementWindowController(editable: mode == .host)
            controller.onEdgeChanged = { [weak self] in
                guard let self, self.isRunning else { return }
                self.stopSession()
                self.startSession()
            }
            controller.isRunning = { [weak self] in self?.isRunning ?? false }
            controller.onStart = { [weak self] in
                guard let self else { return }
                self.stoppedByHand = false
                self.startSession()
            }
            arrangementWindow = controller
        }
        arrangementWindow?.present(headline: headline)
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
        publishControlState()
    }

    @objc private func toggleClipboard() {
        var config = (try? Config.load()) ?? Config()
        config.clipboardSharing.toggle()
        try? config.save()

        if config.clipboardSharing {
            notify("Share clipboard is on", "Turn it on on the other Mac too.")
        }
        // The setting is read when a session starts, so an existing one has to be restarted.
        if isRunning {
            stopSession()
            startSession()
        }
        refresh()
    }

    @objc private func toggleFiles() {
        var config = (try? Config.load()) ?? Config()
        config.fileSharing.toggle()
        try? config.save()
        if config.fileSharing {
            notify("Carry dragged files is on",
                   "Files land in Downloads on the other Mac. Turn it on there too.")
        }
        if isRunning { stopSession(); startSession() }
        refresh()
    }

    @objc private func selectLink(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        applyConfig { $0.preferredLink = raw }
    }

    @objc private func toggleLoginItem() {
        // A switch someone turned off in System Settings can only be turned back on there.
        if LoginItem.needsApproval {
            LoginItem.openSettings()
            notify("Turn Edge on in System Settings",
                   "Edge is switched off under Login Items. Turn it back on there.")
            refresh()
            return
        }
        let outcome = LoginItem.isEnabled ? LoginItem.disable() : LoginItem.enable()
        if case let .finishInSettings(what) = outcome {
            // Taken straight to the place that settles it, rather than told where to look.
            LoginItem.openSettings()
            notify("Finish this in System Settings", what)
        }
        refresh()
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            _ = try? Paths.ensureSupportDirectory()
            FileManager.default.createFile(atPath: logURL.path, contents: Data())
        }
        NSWorkspace.shared.open(logURL)
    }

    @objc private func quit() {
        blinkTimer?.invalidate()
        stopSession()
        NSApp.terminate(nil)
    }

    // MARK: - Control Center

    /// Whether this copy of Edge has its Control Center controls at all: macOS 26 and later,
    /// running as the app with the extension built into it.
    private var controlsAvailable: Bool {
        guard #available(macOS 26.0, *), let plugIns = Bundle.main.builtInPlugInsURL else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: plugIns.appendingPathComponent("EdgeControls.appex").path)
    }

    /// Tells the control what to show, and has WidgetKit redraw it — only when it changed.
    private func publishControlState() {
        guard controlsAvailable else { return }
        let store = (try? SecretStore.load()) ?? SecretStore()
        let state = lastKnownState
        let control = ControlState(paired: !store.pairings.isEmpty,
                                   running: isRunning,
                                   connected: state?.connected == true,
                                   // Not which Mac has the pointer: that changes at every
                                   // crossing, and each change would wake Control Center and
                                   // its extension for a detail nobody looks at there.
                                   pointerAway: false,
                                   isPrimary: mode == .host,
                                   peerName: state?.peerName)
        guard control != lastPublishedControl else { return }
        do {
            try control.write()
        } catch {
            Log.debug("could not write the control state: \(error.localizedDescription)")
            return
        }
        lastPublishedControl = control
        if #available(macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: ControlState.powerKind)
        }
    }

    /// What the Control Center switch asked for.
    ///
    /// On starts Edge. Off is Quit, not Stop: with the menu-bar icon hidden, Control Center
    /// is all there is, and an Edge that merely stopped would carry on running with nothing
    /// left to quit it from. Like Quit, it leaves start at login alone, so the next login
    /// brings Edge back exactly as it would have.
    ///
    /// Deferred a turn, so that when the tap is what launched the app, everything `start()`
    /// queued — the permission check, the secondary readying itself — has happened first and
    /// this sees the state it will actually be acting on.
    func handleControlURL(_ url: URL) {
        guard url.scheme == ControlState.scheme else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch url.host {
            case "start":
                let paired = !(((try? SecretStore.load()) ?? SecretStore()).pairings.isEmpty)
                if !paired {
                    // Nothing to start yet; the menu is where setting up begins.
                    self.showMenuAtPointer()
                } else if !self.isRunning {
                    self.stoppedByHand = false
                    self.startSession()
                }
                self.refresh()
                self.publishControlState()
            case "stop":
                self.quit()
            case "options":
                self.showMenuAtPointer()
            default:
                Log.debug("ignored an unknown control link: \(url.absoluteString)")
            }
        }
    }

    /// The whole menu, where the pointer is — which, after a click in Control Center, is right
    /// beside the control that asked for it.
    private func showMenuAtPointer() {
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Opened by hand while not running — from Finder, Spotlight or Launchpad, not at login
    /// and not by the Control Center switch. Someone who opens an app expects to see it.
    func launchedByHand() {
        guard prefersHiddenIcon else { return }
        prefersHiddenIcon = false
        hiddenByChoice = false
        applyIconVisibility()
        stopReachabilityChecks()
    }

    /// Opening Edge again while it is running, from Finder, Spotlight or Launchpad.
    ///
    /// The way back that cannot be lost, as in most menu-bar apps that let the icon be hidden:
    /// it always brings the icon back, and opens its menu so it is obvious where it went.
    func reopened() {
        if hiddenByChoice {
            prefersHiddenIcon = false
            hiddenByChoice = false
            applyIconVisibility()
            stopReachabilityChecks()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Standing aside for a control in the menu bar, there is no icon to open the menu
            // from; open it where the pointer is instead.
            if self.statusItem.isVisible {
                self.statusItem.button?.performClick(nil)
            } else {
                self.showMenuAtPointer()
            }
        }
    }

    /// The single place that decides whether Edge's own icon shows.
    private func applyIconVisibility() {
        let visible = !hiddenByChoice && !controlInMenuBar
        if statusItem.isVisible != visible { statusItem.isVisible = visible }
    }

    // MARK: Standing aside for a control in the menu bar

    /// Looks every few seconds. Adding a control to the menu bar is not announced to the app
    /// that owns it, and nobody should have to restart Edge to lose a duplicate icon.
    private func startScanningMenuBar() {
        guard controlsAvailable, menuBarScanTimer == nil else { return }
        scanMenuBar()
        menuBarScanTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.scanMenuBar()
        }
        menuBarScanTimer?.tolerance = 2
    }

    private func scanMenuBar() {
        menuBarScanQueue.async { [weak self] in
            let found = MenuBarExtras.edgeControlInMenuBar()
            DispatchQueue.main.async {
                guard let self, found != self.controlInMenuBar else { return }
                self.controlInMenuBar = found
                Log.info(found ? "an Edge control is in the menu bar — hiding Edge's own icon"
                               : "no Edge control in the menu bar — Edge's own icon is back")
                self.applyIconVisibility()
            }
        }
    }

    // MARK: Hiding the menu-bar icon

    /// Never on its own: the icon is only hidden while the Edge switch is in Control Center,
    /// because that switch is how Edge is quit without it. Otherwise Edge would be running
    /// with no way to see it, stop it or quit it.
    private var prefersHiddenIcon: Bool {
        get { UserDefaults.standard.bool(forKey: "hideMenuBarIcon") }
        set { UserDefaults.standard.set(newValue, forKey: "hideMenuBarIcon") }
    }

    /// The Edge controls placed in Control Center or the menu bar, or nil if macOS would not say.
    private func placedControls(_ completion: @escaping (Set<String>?) -> Void) {
        guard controlsAvailable, #available(macOS 26.0, *) else { completion(nil); return }
        Task {
            let kinds: Set<String>?
            do {
                kinds = Set(try await ControlCenter.shared.currentControls().map(\.kind))
            } catch {
                Log.debug("could not list placed controls: \(error.localizedDescription)")
                kinds = nil
            }
            DispatchQueue.main.async { completion(kinds) }
        }
    }

    /// Either control makes hiding safe: turning the switch off quits Edge, and Edge Options
    /// opens this menu, Quit included.
    private static func canQuitFromControlCenter(_ kinds: Set<String>?) -> Bool {
        guard let kinds else { return false }
        return kinds.contains(ControlState.powerKind) || kinds.contains(ControlState.optionsKind)
    }

    /// Shows the icon unless it was hidden *and* the switch is still in Control Center.
    ///
    /// Not knowing counts as "cannot reach": an icon shown that need not be costs a few
    /// pixels, an icon hidden that should not be costs the only way to quit.
    private func applyMenuBarVisibility() {
        guard prefersHiddenIcon else {
            hiddenByChoice = false
            applyIconVisibility()
            stopReachabilityChecks()
            return
        }
        placedControls { [weak self] kinds in
            guard let self, self.prefersHiddenIcon else { return }
            if Self.canQuitFromControlCenter(kinds) {
                self.missedPlacementChecks = 0
                self.hiddenByChoice = true
                self.applyIconVisibility()
                self.startReachabilityChecks()
            } else if self.missedPlacementChecks == 0 {
                // Ask again shortly before believing it.
                self.missedPlacementChecks = 1
                self.startReachabilityChecks()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.applyMenuBarVisibility()
                }
            } else {
                // Removed from Control Center while the icon was hidden: come back, and stay.
                // Re-adding the control later should not make the icon vanish by surprise.
                self.missedPlacementChecks = 0
                self.prefersHiddenIcon = false
                self.hiddenByChoice = false
                self.applyIconVisibility()
                self.stopReachabilityChecks()
                Log.info("Edge is no longer in Control Center — showing the menu-bar icon again")
            }
        }
    }

    private func startReachabilityChecks() {
        guard reachabilityTimer == nil else { return }
        // Removing a control is not announced, so look. Often enough that a missing icon is
        // noticed back within moments; rarely enough to cost nothing.
        reachabilityTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.applyMenuBarVisibility()
        }
        reachabilityTimer?.tolerance = 3
    }

    private func stopReachabilityChecks() {
        reachabilityTimer?.invalidate()
        reachabilityTimer = nil
    }

    @objc private func toggleMenuBarIcon() {
        guard !prefersHiddenIcon else {
            prefersHiddenIcon = false
            hiddenByChoice = false
            applyIconVisibility()
            stopReachabilityChecks()
            return
        }
        placedControls { [weak self] kinds in
            guard let self else { return }
            guard Self.canQuitFromControlCenter(kinds) else {
                self.notify("Add Edge to Control Center first",
                            "Open Control Center ▸ Edit Controls and add Edge or Edge Options.")
                return
            }
            self.prefersHiddenIcon = true
            self.hiddenByChoice = true
            self.applyIconVisibility()
            self.startReachabilityChecks()
            self.notify("Menu bar icon hidden",
                        "Use Edge in Control Center. Open Edge from Applications to bring the icon back.")
        }
    }

    // MARK: - The session process

    private func startSession() {
        guard session?.isRunning != true else { return }
        // Checked here rather than left to the session to discover. The session is a child
        // process: when it exits over a missing checkbox there is nothing on screen at all.
        guard ensurePermissions() else {
            autoStartWork?.cancel()
            autoStartWork = nil
            refresh()
            return
        }
        guard let executable = Bundle.main.executableURL else {
            notify("Edge could not start", "Reinstall Edge, then try again.")
            return
        }

        _ = try? Paths.ensureSupportDirectory()
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: Data())
        }
        guard let log = try? FileHandle(forWritingTo: logURL) else {
            notify("Edge could not start", "It could not open its log file, \(logURL.lastPathComponent).")
            return
        }
        log.seekToEndOfFile()
        log.write(Data("\n--- \(Date()) · starting \(mode.argument) ---\n".utf8))

        if let other = RuntimeState.existing(mode.runtimeRole) {
            let alert = NSAlert()
            alert.messageText = "Edge is already running on this Mac"
            alert.informativeText = "Another Edge session is running, perhaps in Terminal. "
                + "Two at once make the pointer lag."
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
                if finished.terminationStatus == Runtime.exitMissingPermission {
                    // Never retried. Restarting on a timer is right for a dropped link and
                    // exactly wrong here: it turns a missing checkbox into a process that
                    // dies and respawns for ever, silently, which is what this looked like.
                    self.autoStartWork?.cancel()
                    self.autoStartWork = nil
                    self.ensurePermissions()
                } else if finished.terminationStatus != 0
                            && finished.terminationReason != .uncaughtSignal {
                    // The secondary is meant to stay ready, so a session that fell over comes
                    // back by itself rather than needing someone to walk over to that Mac.
                    if self.mode == .client && !self.stoppedByHand {
                        Log.warn("the listener exited (status \(finished.terminationStatus)); starting it again")
                        self.scheduleAutoStart(after: 3)
                    } else {
                        self.notify("Edge stopped unexpectedly",
                                    "Choose Start to try again. Help ▸ Open log shows what happened.")
                    }
                }
                self.refresh()
            }
        }

        do {
            try process.run()
            session = process
            setupCompleted = true
        } catch {
            notify("Edge could not start", error.localizedDescription)
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
    // Whether Edge opens at login is the Start at login switch's decision alone. Without this,
    // macOS reopens whatever was running at logout, and Edge comes back with the switch off.
    app.disableRelaunchOnLogin()
    let controller = MenuBarController()
    // Kept alive for the life of the app: NSApplication holds its delegate weakly.
    let delegate = MenuBarAppDelegate(controller: controller)
    app.delegate = delegate
    controller.start()
    withExtendedLifetime(delegate) { app.run() }
    exit(0)
}

/// The two things only an application delegate is told about.
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private let controller: MenuBarController

    init(controller: MenuBarController) {
        self.controller = controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The event that launched us says how: the Control Center switch sends a link instead
        // of an open-application event, and a login item marks its open-application event as
        // such. Anything else is someone opening Edge on purpose.
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return }
        let loginItem = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?
            .enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if !loginItem { controller.launchedByHand() }
    }

    /// A tap on the Control Center switch — including the one that launched the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(controller.handleControlURL)
    }

    /// Opened again while already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.reopened()
        return false
    }
}
