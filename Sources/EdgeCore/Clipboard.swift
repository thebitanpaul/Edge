import Foundation
import AppKit

/// Clipboard contents in a form both Macs agree on.
///
/// A pasteboard item carries the same thing in several representations at once — styled text
/// also appears as plain text, an image as both PNG and TIFF. Sending all of them would waste
/// the link, and sending only the richest would lose the paste on the other side if it cannot
/// read that type. So a small ordered set is carried and the receiver picks what it wants.
public struct ClipboardContents: Sendable, Equatable {
    public struct Representation: Sendable, Equatable {
        public let type: String      // a pasteboard UTI
        public let data: Data
        public init(type: String, data: Data) { self.type = type; self.data = data }
    }

    public var representations: [Representation]

    public init(representations: [Representation]) {
        self.representations = representations
    }

    public var totalBytes: Int { representations.reduce(0) { $0 + $1.data.count } }

    public var isEmpty: Bool { representations.isEmpty }

    /// A short description for logs and the menu, with no clipboard content in it.
    ///
    /// Deliberately never includes the text: whatever you last copied is frequently a
    /// password, and a log file is a poor place for it.
    public var summary: String {
        guard let first = representations.first else { return "empty" }
        let kind: String
        switch first.type {
        case let t where t.contains("plain-text"), let t where t.contains("utf8"): kind = "text"
        case let t where t.contains("rtf"): kind = "rich text"
        case let t where t.contains("png"), let t where t.contains("tiff"): kind = "image"
        case let t where t.contains("html"): kind = "html"
        default: kind = first.type
        }
        return "\(kind), \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .binary))"
    }

    // MARK: wire format
    //
    // [u8 count] then, per representation, [u16 type length][type][u32 data length][data].

    public func encoded() -> Data {
        var w = BinaryWriter(capacity: totalBytes + 64)
        w.u8(UInt8(min(representations.count, 255)))
        for rep in representations.prefix(255) {
            w.string(rep.type)
            w.u32(UInt32(rep.data.count))
            w.blob(rep.data)
        }
        return w.data
    }

    public static func decode(_ data: Data, limit: Int) throws -> ClipboardContents {
        var r = BinaryReader(data)
        let count = Int(try r.u8())
        var reps: [Representation] = []
        var total = 0
        for _ in 0..<count {
            let type = try r.string()
            let length = Int(try r.u32())
            total += length
            guard total <= limit else {
                throw EdgeError.invalidArgument("clipboard payload exceeds the \(limit) byte limit")
            }
            reps.append(Representation(type: type, data: try r.blob(length)))
        }
        return ClipboardContents(representations: reps)
    }
}

/// Watches this Mac's pasteboard and applies what the other Mac sends.
///
/// Polling rather than notifications because AppKit offers no pasteboard-changed callback;
/// `changeCount` is the documented way and comparing one integer a couple of times a second
/// costs nothing measurable.
public final class ClipboardSync {
    /// Types worth carrying, richest first. File URLs are deliberately absent: a path that
    /// means something on one Mac means nothing, or something else, on the other.
    private static let textTypes: [NSPasteboard.PasteboardType] = [
        .rtf, .html, .string,
    ]
    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
    ]

    private let pasteboard: NSPasteboard
    private let queue = DispatchQueue(label: "app.edge.clipboard")
    private var timer: DispatchSourceTimer?

    /// The change count we last saw, so our own writes are not read back and re-sent.
    private var lastSeenChange: Int
    private let lock = NSLock()

    public var includeImages: Bool
    public var sizeLimit: Int

    /// Called when this Mac's clipboard changes and should be sent to the other one.
    public var onLocalChange: ((ClipboardContents) -> Void)?

    public init(includeImages: Bool = false, sizeLimit: Int = 1 << 20,
                pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.includeImages = includeImages
        self.sizeLimit = sizeLimit
        self.lastSeenChange = pasteboard.changeCount
    }

    public func start(interval: TimeInterval = 0.4) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Runs one polling cycle immediately. Only for tests, which cannot wait on a timer.
    public func pollForTesting() { poll() }

    private func poll() {
        let current = pasteboard.changeCount
        lock.lock()
        let changed = current != lastSeenChange
        if changed { lastSeenChange = current }
        lock.unlock()
        guard changed else { return }

        guard let contents = read() else { return }
        guard !contents.isEmpty else { return }
        guard contents.totalBytes <= sizeLimit else {
            Log.debug("not sending a \(contents.summary) clipboard: over the \(sizeLimit) byte limit")
            return
        }
        Log.debug("clipboard changed here (\(contents.summary))")
        onLocalChange?(contents)
    }

    /// Reads the current pasteboard into the representations worth sending.
    public func read() -> ClipboardContents? {
        var wanted = Self.textTypes
        if includeImages { wanted += Self.imageTypes }

        var reps: [ClipboardContents.Representation] = []
        for type in wanted {
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            reps.append(.init(type: type.rawValue, data: data))
        }
        return reps.isEmpty ? nil : ClipboardContents(representations: reps)
    }

    /// Puts the other Mac's clipboard onto this one, without sending it straight back.
    public func apply(_ contents: ClipboardContents) {
        guard !contents.isEmpty else { return }
        pasteboard.clearContents()
        for rep in contents.representations {
            pasteboard.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type))
        }
        // Record the change count our own write produced, so the next poll sees nothing new.
        // Without this the two Macs hand the same clipboard back and forth indefinitely.
        lock.lock()
        lastSeenChange = pasteboard.changeCount
        lock.unlock()
        Log.debug("applied the other Mac's clipboard (\(contents.summary))")
    }
}

/// Keeps two Macs' clipboards in step over an established link.
///
/// Both ends run one of these; it is symmetric, unlike the pointer. Nothing is sent unless
/// *both* Macs advertised the clipboard capability, so turning it off on either machine is
/// enough to stop it — you do not have to trust the other side to respect your setting.
public final class ClipboardBridge {
    private let sync: ClipboardSync
    private let enabledLocally: Bool
    private var peerAgrees = false
    private let send: @Sendable (Message) -> Void
    private let lock = NSLock()

    public var onActivity: ((String) -> Void)?

    public init(config: Config, send: @escaping @Sendable (Message) -> Void) {
        self.enabledLocally = config.clipboardSharing
        self.send = send
        self.sync = ClipboardSync(includeImages: config.clipboardImages,
                                  sizeLimit: config.clipboardLimit)
    }

    /// Starts watching, if this Mac and the peer both want it.
    public func attach(peerCapabilities: Capabilities) {
        lock.lock()
        peerAgrees = peerCapabilities.contains(.clipboard)
        let active = enabledLocally && peerAgrees
        lock.unlock()

        guard active else {
            if enabledLocally {
                Log.info("clipboard sharing is on here but off on the other Mac — not syncing")
            }
            return
        }
        sync.onLocalChange = { [weak self] contents in
            guard let self else { return }
            self.send(.clipboard(kind: "edge/v1", payload: contents.encoded()))
            self.onActivity?("sent \(contents.summary)")
        }
        sync.start()
        Log.info("clipboard sharing is on")
    }

    public func detach() {
        sync.stop()
        sync.onLocalChange = nil
        lock.lock(); peerAgrees = false; lock.unlock()
    }

    /// Feed every message; anything that is not a clipboard is ignored.
    public func handle(_ message: Message, limit: Int) {
        guard case let .clipboard(_, payload) = message else { return }
        lock.lock()
        let active = enabledLocally && peerAgrees
        lock.unlock()
        guard active else {
            Log.debug("ignoring a clipboard from the other Mac: sharing is off here")
            return
        }
        do {
            let contents = try ClipboardContents.decode(payload, limit: limit)
            sync.apply(contents)
            onActivity?("received \(contents.summary)")
        } catch {
            Log.warn("could not read the other Mac's clipboard: \(error.localizedDescription)")
        }
    }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabledLocally && peerAgrees
    }
}
