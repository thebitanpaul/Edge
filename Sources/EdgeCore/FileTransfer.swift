import Foundation

/// Carrying dragged files across the link.
///
/// The gesture is the point: you drag a file at the shared edge and it arrives on the other
/// Mac. What it deliberately does *not* try to do is drop the file into whatever application
/// happens to be under the pointer over there. That needs a synthetic drag session on the
/// receiving side, which is the part every implementation of this — Synergy's, and Deskflow's
/// after it — has failed to make dependable; Deskflow has since removed the feature outright.
/// Landing the files in a folder is a promise that can be kept every time.
public enum FileTransfer {
    /// Where arriving files are put.
    public static var destination: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// A name that cannot escape the folder it is meant to land in.
    ///
    /// The sender has already proven it holds the pairing key, so this is not the boundary
    /// that keeps strangers out. It is the one that keeps a bug on the other side — or a file
    /// genuinely named something awkward — from writing outside the destination.
    public static func safeName(_ raw: String) -> String {
        let collapsed = raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty || collapsed == "." || collapsed == ".." { return "Received file" }
        return String(collapsed.prefix(255))
    }

    /// `name`, or `name 2`, or `name 3` — whichever is free in `directory`.
    public static func uniqueURL(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = directory.appendingPathComponent(next)
            n += 1
            if n > 1000 { break }
        }
        return candidate
    }
}

/// Reads files off disk and feeds them to the link a chunk at a time.
public final class FileSender {
    private let link: SecureLink
    private let transfer: UInt32
    private var sources: [URL] = []
    private var temporaries: [URL] = []
    private var index = 0
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "app.edge.files.send")

    /// Called with the number of files and total bytes once the offer has gone out.
    public var onStarted: ((Int, UInt64) -> Void)?
    /// Called once, with nil on success or a reason on failure.
    public var onFinished: ((String?) -> Void)?

    public init(link: SecureLink, transfer: UInt32 = UInt32.random(in: 1...UInt32.max)) {
        self.link = link
        self.transfer = transfer
    }

    /// Starts sending. Returns false, having sent nothing, if there is nothing sendable.
    @discardableResult
    public func start(urls: [URL]) -> Bool {
        let prepared = Self.prepare(urls)
        guard !prepared.entries.isEmpty else { return false }
        sources = prepared.sources
        temporaries = prepared.temporaries

        let total = prepared.entries.reduce(UInt64(0)) { $0 + $1.size }
        guard total <= FileLimits.maxTotalBytes else {
            finish("that is more than \(FileLimits.maxTotalBytes / (1024 * 1024 * 1024)) GB")
            return false
        }

        link.send(.fileOffer(transfer: transfer, files: prepared.entries))
        onStarted?(prepared.entries.count, total)
        queue.async { [weak self] in self?.openNext() }
        return true
    }

    /// Expands what was dragged into a flat list of ordinary files.
    ///
    /// A folder cannot be streamed as one file, and refusing to carry one would make the
    /// gesture unpredictable — people drag folders. `ditto` zips it first, which is the same
    /// thing Finder does when it compresses, and the name says so.
    private static func prepare(_ urls: [URL]) -> (sources: [URL], temporaries: [URL], entries: [FileEntry]) {
        let fm = FileManager.default
        var sources: [URL] = []
        var temporaries: [URL] = []
        var entries: [FileEntry] = []

        for url in urls.prefix(FileLimits.maxFiles) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            var source = url
            if isDirectory.boolValue {
                guard let zipped = zip(url) else {
                    Log.warn("could not compress \(url.lastPathComponent) to send it")
                    continue
                }
                source = zipped
                temporaries.append(zipped)
            }
            guard let size = (try? fm.attributesOfItem(atPath: source.path)[.size]) as? NSNumber
            else { continue }
            sources.append(source)
            entries.append(FileEntry(name: source.lastPathComponent, size: size.uint64Value))
        }
        return (sources, temporaries, entries)
    }

    private static func zip(_ directory: URL) -> URL? {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let destination = temp.appendingPathComponent(directory.lastPathComponent + ".zip")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                          directory.path, destination.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else { return nil }
        return destination
    }

    private func openNext() {
        handle?.closeFile()
        handle = nil
        guard index < sources.count else {
            link.send(.fileEnd(transfer: transfer, ok: true, message: ""))
            finish(nil)
            return
        }
        guard let opened = try? FileHandle(forReadingFrom: sources[index]) else {
            fail("could not read \(sources[index].lastPathComponent)")
            return
        }
        handle = opened
        sendChunk()
    }

    private func sendChunk() {
        guard let handle else { return }
        let data = handle.readData(ofLength: FileLimits.chunkBytes)
        guard !data.isEmpty else {
            index += 1
            openNext()
            return
        }
        link.send(.fileChunk(transfer: transfer, index: UInt32(index), data: data)) { [weak self] sent in
            guard let self else { return }
            guard sent else { self.queue.async { self.fail("the link closed") }; return }
            self.queue.async { self.sendChunk() }
        }
    }

    private func fail(_ reason: String) {
        link.send(.fileEnd(transfer: transfer, ok: false, message: reason))
        finish(reason)
    }

    public func cancel(reason: String) {
        queue.async { [weak self] in self?.fail(reason) }
    }

    private func finish(_ reason: String?) {
        handle?.closeFile()
        handle = nil
        for temp in temporaries {
            try? FileManager.default.removeItem(at: temp.deletingLastPathComponent())
        }
        temporaries = []
        let callback = onFinished
        onFinished = nil
        callback?(reason)
    }
}

/// Collects an arriving transfer and puts the files where they can be found.
public final class FileReceiver {
    private let directory: URL
    private var transfer: UInt32?
    private var staging: URL?
    private var staged: [URL] = []
    private var names: [String] = []
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var handles: [Int: FileHandle] = [:]
    private let lock = NSLock()

    /// Called with the finished files, on whatever queue the link delivers messages on.
    public var onReceived: (([URL], String) -> Void)?
    public var onFailed: ((String) -> Void)?

    public init(directory: URL = FileTransfer.destination) {
        self.directory = directory
    }

    public func handle(_ message: Message, from peerName: String) {
        switch message {
        case let .fileOffer(id, files):
            begin(id, files)
        case let .fileChunk(id, index, data):
            append(id, Int(index), data)
        case let .fileEnd(id, ok, reason):
            end(id, ok: ok, reason: reason, peerName: peerName)
        default:
            break
        }
    }

    /// Drops a transfer in progress. Called when the link goes away mid-file, so a half
    /// written file never appears in the destination folder looking complete.
    public func abandon() {
        lock.lock(); defer { lock.unlock() }
        discard()
    }

    private func begin(_ id: UInt32, _ files: [FileEntry]) {
        lock.lock(); defer { lock.unlock() }
        discard()

        let total = files.reduce(UInt64(0)) { $0 + $1.size }
        guard !files.isEmpty, files.count <= FileLimits.maxFiles,
              total <= FileLimits.maxTotalBytes else {
            onFailed?("refused a transfer of \(files.count) file(s), \(total) bytes")
            return
        }

        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-incoming-\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: stage)
        guard (try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true))
                != nil else {
            onFailed?("could not make room for the incoming files")
            return
        }

        transfer = id
        staging = stage
        expected = total
        received = 0
        names = files.map { FileTransfer.safeName($0.name) }
        staged = names.map { stage.appendingPathComponent($0) }
        for url in staged {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        Log.info("receiving \(files.count) file(s), \(total) bytes")
    }

    private func append(_ id: UInt32, _ index: Int, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard transfer == id, index >= 0, index < staged.count else { return }
        received += UInt64(data.count)
        guard received <= expected else {
            onFailed?("the other Mac sent more than it offered")
            discard()
            return
        }
        if handles[index] == nil {
            handles[index] = try? FileHandle(forWritingTo: staged[index])
        }
        guard let handle = handles[index] else { return }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    private func end(_ id: UInt32, ok: Bool, reason: String, peerName: String) {
        lock.lock()
        guard transfer == id else { lock.unlock(); return }
        for handle in handles.values { handle.closeFile() }
        handles.removeAll()

        guard ok else {
            discard()
            lock.unlock()
            onFailed?(reason.isEmpty ? "the other Mac stopped sending" : reason)
            return
        }

        var landed: [URL] = []
        for (url, name) in zip(staged, names) {
            let target = FileTransfer.uniqueURL(for: name, in: directory)
            do {
                try FileManager.default.moveItem(at: url, to: target)
                landed.append(target)
            } catch {
                Log.warn("could not put \(name) in \(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
        discard()
        lock.unlock()

        if landed.isEmpty {
            onFailed?("nothing could be written to \(directory.lastPathComponent)")
        } else {
            onReceived?(landed, peerName)
        }
    }

    /// Caller holds the lock.
    private func discard() {
        for handle in handles.values { handle.closeFile() }
        handles.removeAll()
        if let staging { try? FileManager.default.removeItem(at: staging) }
        staging = nil
        staged = []
        names = []
        transfer = nil
        expected = 0
        received = 0
    }
}
