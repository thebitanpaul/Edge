import AppKit
import EdgeCore

/// Draws the two Macs' screens the way the Displays settings draw one Mac's.
///
/// It replaced an ASCII diagram inside an alert, which was legible but not something you could
/// look at and immediately understand. Rectangles to scale, in proportion, with the edge you
/// cross marked — the question "is this arrangement right?" should be answerable at a glance.
final class ArrangementView: NSView {
    var layout: ScreenLayout?
    var localName = "This Mac"
    var remoteName = "The other Mac"

    override var isFlipped: Bool { true }   // screen coordinates run downwards

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        guard let layout,
              let world = ScreenRect.union(layout.localDisplays + layout.remoteDisplaysInVirtual),
              world.width > 0, world.height > 0 else {
            drawCentred("Not connected yet", in: bounds, color: .secondaryLabelColor,
                        size: 13, weight: .regular)
            return
        }

        let inset: CGFloat = 16
        let canvas = bounds.insetBy(dx: inset, dy: inset)
        let scale = min(canvas.width / world.width, canvas.height / world.height)
        let drawnWidth = world.width * scale
        let drawnHeight = world.height * scale
        let originX = canvas.minX + (canvas.width - drawnWidth) / 2
        let originY = canvas.minY + (canvas.height - drawnHeight) / 2

        func place(_ r: ScreenRect) -> NSRect {
            NSRect(x: originX + (r.x - world.x) * scale,
                   y: originY + (r.y - world.y) * scale,
                   width: max(2, r.width * scale),
                   height: max(2, r.height * scale))
        }

        for (rects, isLocal) in [(layout.localDisplays, true),
                                 (layout.remoteDisplaysInVirtual, false)] {
            for rect in rects {
                let frame = place(rect).insetBy(dx: 1.5, dy: 1.5)
                let path = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
                (isLocal ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                         : NSColor.systemGray.withAlphaComponent(0.16)).setFill()
                path.fill()
                (isLocal ? NSColor.controlAccentColor
                         : NSColor.systemGray).setStroke()
                path.lineWidth = isLocal ? 2 : 1.5
                path.stroke()
            }
        }

        // Name each Mac once, over its own screens, rather than labelling every rectangle.
        if let localBox = ScreenRect.union(layout.localDisplays) {
            drawCentred(localName, in: place(localBox), color: .labelColor, size: 12, weight: .semibold)
        }
        if let remoteBox = ScreenRect.union(layout.remoteDisplaysInVirtual) {
            drawCentred(remoteName, in: place(remoteBox), color: .secondaryLabelColor,
                        size: 12, weight: .semibold)
        }
    }

    private func drawCentred(_ text: String, in rect: NSRect, color: NSColor,
                             size: CGFloat, weight: NSFont.Weight) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        guard measured.width < rect.width - 4 else { return }
        (text as NSString).draw(
            at: NSPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2),
            withAttributes: attributes)
    }
}

/// The window around that view, with the controls that change what it shows.
final class ArrangementWindowController: NSWindowController {
    private let view = ArrangementView()
    private var note: NSTextField!
    private var startButton: NSButton!
    private let isEditable: Bool

    init(editable: Bool) {
        self.isEditable = editable
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Screen arrangement"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let window, let content = window.contentView else { return }

        view.frame = NSRect(x: 0, y: 180, width: 520, height: 280)
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)

        note = NSTextField(labelWithString: "")
        note.frame = NSRect(x: 20, y: 152, width: 480, height: 18)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        content.addSubview(note)

        let caption = NSTextField(labelWithString: isEditable
            ? "Where the other Mac sits"
            : "Set on the primary Mac")
        caption.frame = NSRect(x: 20, y: 126, width: 480, height: 18)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        content.addSubview(caption)

        let titles: [(ScreenEdge, String)] = [(.left, "Left"), (.right, "Right"),
                                              (.top, "Above"), (.bottom, "Below")]
        let segmented = NSSegmentedControl(labels: titles.map(\.1), trackingMode: .selectOne,
                                           target: self, action: #selector(edgeChanged(_:)))
        segmented.frame = NSRect(x: 110, y: 92, width: 300, height: 26)
        segmented.isEnabled = isEditable
        let config = (try? Config.load()) ?? Config()
        segmented.selectedSegment = titles.firstIndex { $0.0 == config.edge } ?? 1
        content.addSubview(segmented)

        // Alignment matters only when the screens are different sizes, which is why it sits
        // here rather than in the menu: next to a picture that shows whether it looks right.
        let alignment = NSPopUpButton(frame: NSRect(x: 110, y: 62, width: 300, height: 22),
                                      pullsDown: false)
        alignment.addItems(withTitles: ArrangementWindowController.alignmentTitles.map(\.1))
        alignment.selectItem(at: ArrangementWindowController.alignmentTitles
            .firstIndex { $0.0 == config.alignment } ?? 0)
        alignment.target = self
        alignment.action = #selector(alignmentChanged(_:))
        alignment.isEnabled = isEditable
        alignment.isBordered = false
        content.addSubview(alignment)

        // Arranging the screens and starting are one act, not two. Making someone close this
        // window and then find Start in the menu put a step between a decision and its effect,
        // and the arrangement is not worth looking at until the pointer can actually use it.
        startButton = NSButton(frame: NSRect(x: 396, y: 16, width: 104, height: 32))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startOrClose)
        startButton.isHidden = !isEditable
        content.addSubview(startButton)
    }

    /// Starts the session if it is not running, and closes either way.
    @objc private func startOrClose() {
        let wasRunning = isRunning?() ?? false
        close()
        if !wasRunning { onStart?() }
    }

    static let alignmentTitles: [(ScreenAlignment, String)] = [
        (.proportional, "Stretch to fit"),
        (.start, "Line up the tops"),
        (.center, "Line up the middles"),
        (.end, "Line up the bottoms"),
    ]

    @objc private func alignmentChanged(_ sender: NSPopUpButton) {
        let choices = Self.alignmentTitles
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < choices.count else { return }
        var config = (try? Config.load()) ?? Config()
        config.remoteAlignment = choices[sender.indexOfSelectedItem].0.rawValue
        try? config.save()
        onEdgeChanged?()
        reload()
    }

    @objc private func edgeChanged(_ sender: NSSegmentedControl) {
        let edges: [ScreenEdge] = [.left, .right, .top, .bottom]
        guard sender.selectedSegment >= 0, sender.selectedSegment < edges.count else { return }
        var config = (try? Config.load()) ?? Config()
        config.remoteEdge = edges[sender.selectedSegment].rawValue
        try? config.save()
        onEdgeChanged?()
        reload()
    }

    /// Called when the arrangement is changed, so a running session can be restarted.
    var onEdgeChanged: (() -> Void)?
    /// Starts the session. Nil on the secondary, which starts itself.
    var onStart: (() -> Void)?
    /// Whether a session is up, so the button can say Start or Done.
    var isRunning: (() -> Bool)?

    func reload() {
        if let startButton {
            let running = isRunning?() ?? false
            startButton.title = running ? "Done" : "Start"
            startButton.isHidden = !isEditable
        }
        let config = (try? Config.load()) ?? Config()
        let store = (try? SecretStore.load()) ?? SecretStore()
        let identity = try? Identity.loadOrCreate()
        view.localName = identity?.deviceName ?? "This Mac"

        guard let pairing = store.pairings.first(where: { ($0.peerDisplays?.isEmpty == false) }),
              let remote = pairing.peerDisplays else {
            view.layout = nil
            note.stringValue = "Connect the two Macs once and the arrangement appears here."
            view.needsDisplay = true
            return
        }

        view.remoteName = pairing.peerName ?? pairing.label
        view.layout = ScreenLayout(localDisplays: Displays.current(), remoteDisplays: remote,
                                   edge: config.edge, alignment: config.alignment)
        note.stringValue = view.layout == nil
            ? "No displays to arrange."
            : "\(Displays.current().count) screen(s) here, \(remote.count) there"
        view.needsDisplay = true
    }

    func present() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
