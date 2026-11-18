import AppKit
import EdgeCore

/// The pairing window.
///
/// This replaced three chained `NSAlert`s, and not for appearance. An alert blocks the thread
/// in its own modal session, so progress arriving from the network had to dismiss it — and
/// when the other Mac was already waiting, it was found in the milliseconds *before* the modal
/// began. `abortModal()` with no session running does nothing, so the dialog then sat there
/// for ever while the pairing it was waiting for had already succeeded.
///
/// A window that updates in place has no such ordering to get wrong: state arrives, the
/// window redraws.
///
/// Pairing happens over the shared network, not over a cable. `mDNS` does advertise on a
/// Thunderbolt interface — that much was measured — but the two Macs finding *each other*
/// across a direct bridge proved unreliable in practice, in one direction only, which is the
/// worst way for a thing to not work. Pairing once over Wi-Fi costs nothing and always works;
/// the cable then carries the actual link, which is where its speed matters and where it is
/// entirely dependable.
final class PairingWindowController: NSWindowController, NSWindowDelegate {

    private enum Stage {
        case searching
        case verifying(digits: String, peer: String)
        case waitingForPeer(peer: String)
        case failed(String)
    }

    private let identity: Identity
    private let link: LinkPreference
    private var session: NetworkPairingSession?
    private var stage: Stage = .searching

    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let digits = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()

    var onPaired: ((NetworkPairing.Outcome) -> Void)?

    init(identity: Identity, link: LinkPreference) {
        self.identity = identity
        self.link = link
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 236),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Connect to a nearby Mac"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The title bar's close button closes the window directly, never calling `close()`
    /// below — which left pairing advertising and listening for its full three minutes.
    func windowWillClose(_ notification: Notification) {
        session?.cancel()
        session = nil
    }

    // MARK: - Layout

    private func build() {
        guard let content = window?.contentView else { return }

        title.frame = NSRect(x: 24, y: 178, width: 372, height: 24)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        content.addSubview(title)

        detail.frame = NSRect(x: 24, y: 118, width: 372, height: 56)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        detail.lineBreakMode = .byWordWrapping
        content.addSubview(detail)

        digits.frame = NSRect(x: 24, y: 112, width: 372, height: 48)
        digits.font = .monospacedDigitSystemFont(ofSize: 38, weight: .medium)
        digits.alignment = .center
        digits.isHidden = true
        content.addSubview(digits)

        spinner.frame = NSRect(x: 24, y: 84, width: 18, height: 18)
        spinner.style = .spinning
        spinner.controlSize = .small
        content.addSubview(spinner)

        // 20 points of gap, not an overlap of 28: the old pair ran 148–286 and 258–396.
        for (button, x) in [(primaryButton, 272), (secondaryButton, 132)] {
            button.frame = NSRect(x: CGFloat(x), y: 20, width: 124, height: 30)
            button.bezelStyle = .rounded
            button.target = self
            content.addSubview(button)
        }
        primaryButton.keyEquivalent = "\r"
        primaryButton.action = #selector(primaryTapped)
        secondaryButton.action = #selector(secondaryTapped)
    }

    // MARK: - Running

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        startSearching()
    }

    private func startSearching() {
        session?.cancel()
        let session = NetworkPairingSession(identity: identity, link: link)
        session.onProgress = { [weak self] progress in
            // Already on the main thread; the session promises that.
            self?.apply(progress)
        }
        self.session = session
        stage = .searching
        session.start()
        render()
    }

    private func apply(_ progress: NetworkPairingSession.Progress) {
        switch progress {
        case .waiting:
            break
        case .found:
            break
        case let .verify(digits, peer):
            stage = .verifying(digits: digits, peer: peer)
        case let .failed(reason):
            // The same reasons the terminal prints, which start in lower case; a sentence here.
            stage = .failed(reason.prefix(1).uppercased() + reason.dropFirst())
        case let .done(outcome):
            onPaired?(outcome)
            close()
            return
        }
        render()
    }

    private func render() {
        digits.isHidden = true
        detail.isHidden = false
        // Hidden, not merely stopped: a visible wheel that is not turning looks like a hang.
        spinner.isHidden = true

        switch stage {
        case .searching:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            title.stringValue = "Looking for the other Mac"
            detail.stringValue = "On the other Mac, choose Connect to a nearby Mac… too.\n"
                + "Both need to be on the same network."
            primaryButton.title = "Search again"
            primaryButton.isEnabled = true
            secondaryButton.title = "Cancel"
            secondaryButton.isHidden = false

        case let .verifying(value, peer):
            spinner.stopAnimation(nil)
            title.stringValue = "Does \(peer) show this?"
            detail.isHidden = true
            digits.isHidden = false
            digits.stringValue = value
            primaryButton.title = "They match"
            primaryButton.isEnabled = true
            secondaryButton.title = "They differ"
            secondaryButton.isHidden = false

        case let .waitingForPeer(peer):
            spinner.isHidden = false
            spinner.startAnimation(nil)
            title.stringValue = "Waiting for \(peer)"
            detail.stringValue = "Confirm the same number over there."
            primaryButton.title = "Waiting"
            primaryButton.isEnabled = false
            secondaryButton.title = "Cancel"
            secondaryButton.isHidden = false

        case let .failed(reason):
            spinner.stopAnimation(nil)
            title.stringValue = "Not paired"
            detail.stringValue = reason
            primaryButton.title = "Try again"
            primaryButton.isEnabled = true
            secondaryButton.title = "Close"
            secondaryButton.isHidden = false
        }
    }

    // MARK: - Buttons

    @objc private func primaryTapped() {
        switch stage {
        case .searching, .failed:
            startSearching()
        case let .verifying(_, peer):
            session?.confirm(true)
            stage = .waitingForPeer(peer: peer)
            render()
        case .waitingForPeer:
            break
        }
    }

    @objc private func secondaryTapped() {
        switch stage {
        case .verifying:
            session?.confirm(false)
            stage = .failed("The numbers did not match. Try again; if they differ every time, "
                            + "something on this network may be interfering — try another network.")
            render()
        default:
            session?.cancel()
            close()
        }
    }

    override func close() {
        session?.cancel()
        session = nil
        super.close()
    }
}
