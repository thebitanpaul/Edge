import Foundation
import Network
import EdgeCore

/// End-to-end check that runs entirely on one Mac over loopback.
///
/// Worth having before you touch the second machine: it proves the crypto, the codec and the
/// transport work here, so anything that fails later is a network or pairing problem rather
/// than a build problem. It also exercises the two failure paths that matter — a wrong key and
/// an unrecognised device — because "it rejects the right things" is the half of a security
/// feature that normally goes untested.
extension Commands {

    private struct Check {
        let name: String
        var passed: Bool
        var detail: String
    }

    static func selftest(_ args: Args) throws {
        var checks: [Check] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(Check(name: name, passed: passed, detail: detail))
            if passed { ok("\(name)\(detail.isEmpty ? "" : "  \(Style.dim(detail))")") }
            else { bad("\(name)  \(detail)") }
        }

        out(Style.bold("Edge self-test"))
        out(Style.dim("  loopback only — nothing leaves this Mac"))
        out()

        // ---- 1. Pairing codes -------------------------------------------------
        out(Style.bold("Pairing codes"))
        let code = PairingCode.generate()
        let reparsed = try? PairingCode.parse(code.formatted)
        record("code survives a round trip",
               reparsed.map { Crypto.constantTimeEquals($0.secret, code.secret) } ?? false,
               code.formatted)

        var mangled = Array(code.formatted)
        if let idx = mangled.firstIndex(where: { $0.isNumber || ($0.isLetter && $0 != "-") }) {
            mangled[idx] = mangled[idx] == "7" ? "8" : "7"
        }
        let typo = String(mangled)
        var typoRejected = false
        do { _ = try PairingCode.parse(typo) } catch { typoRejected = true }
        record("a single-character typo is rejected", typoRejected, "checksum caught it")

        record("derived keys are independent",
               !Crypto.constantTimeEquals(code.psk, Crypto.deriveAuthKey(fromPSK: code.psk)),
               "psk ≠ auth key")

        // ---- 2. Codec ---------------------------------------------------------
        out()
        out(Style.bold("Wire protocol"))
        let samples: [Message] = [
            .hello(protocolVersion: Wire.protocolVersion, deviceID: DeviceID(), deviceName: "Test Mac",
                   hostName: "test-mac", role: .host, capabilities: .baseline,
                   nonce: Crypto.randomBytes(32), keyID: Crypto.randomBytes(8)),
            .ping(seq: 42, sentAt: 1_234_567_890),
            .mouseMove(x: -1920, y: 1080, dx: -3, dy: 7),
            .mouseButton(button: .right, down: true, clickCount: 2, x: 10, y: 20),
            .scroll(dx: 0, dy: -12, isPixel: true),
            .keyEvent(keyCode: 0x24, down: true, isRepeat: false, flags: 0x0010_0000),
            .flagsChanged(flags: 0x0008_0000),
            .screenInfo(displays: [Display(x: 0, y: 0, width: 3456, height: 2234, isMain: true),
                                   Display(x: 3456, y: 0, width: 2560, height: 1440, isMain: false)]),
            .bye(reason: "ok"),
            .fileOffer(transfer: 7, files: [FileEntry(name: "notes.txt", size: 12),
                                            FileEntry(name: "Archive.zip", size: 9_000_000)]),
            .fileChunk(transfer: 7, index: 1, data: Crypto.randomBytes(4096)),
            .fileEnd(transfer: 7, ok: true, message: ""),
            .fileRequest,
        ]
        var codecOK = true
        var codecDetail = ""
        for message in samples {
            let frame = Codec.encodeFrame(message)
            let declared = Int(frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            guard declared == frame.count - 4 else {
                codecOK = false; codecDetail = "bad length prefix on \(message.type)"; break
            }
            let payload = frame.dropFirst(5)
            do {
                let decoded = try Codec.decode(type: frame[frame.startIndex + 4], payload: Data(payload))
                guard decoded.type == message.type,
                      Codec.encodePayload(decoded) == Codec.encodePayload(message) else {
                    codecOK = false; codecDetail = "\(message.type) did not round-trip"; break
                }
            } catch {
                codecOK = false; codecDetail = "\(message.type): \(error)"; break
            }
        }
        record("all \(samples.count) message types round-trip", codecOK, codecDetail)
        record("a mouse move is \(Codec.encodeFrame(.mouseMove(x: 0, y: 0, dx: 0, dy: 0)).count) bytes on the wire", true)

        var oversizeRejected = false
        do { _ = try Codec.decode(type: 0xEE, payload: Data()) } catch { oversizeRejected = true }
        record("unknown message types are rejected", oversizeRejected)

        var truncationRejected = false
        do { _ = try Codec.decode(type: MessageType.mouseMove.rawValue, payload: Data([1, 2, 3])) }
        catch { truncationRejected = true }
        record("truncated payloads are rejected", truncationRejected)

        // ---- 3. Secure transport ---------------------------------------------
        out()
        out(Style.bold("Secure transport (loopback)"))

        let identity = try Identity.loadOrCreate()
        var ephemeral = SecretStore()
        ephemeral.pairings = [Pairing(psk: code.psk, label: "selftest")]
        // Never touches the real secrets file: the directory is constructed in memory and the
        // `mutate` path (the only thing that writes) is not used here.
        let directory = PairingDirectory(store: ephemeral, inMemory: true)

        let listener = LinkListener(
            identity: identity,
            localRole: .client,
            options: .init(port: 0, requireLocalNetwork: true, bonjourName: nil,
                           handshakeTimeout: 5, loopbackOnly: true),
            keys: [PSKEntry(psk: code.psk)],
            resolvePSK: { [weak directory] in directory?.psk(forKeyID: $0) },
            authorizePeer: { [weak directory] in directory?.authorize(deviceID: $0, keyID: $1) ?? false })

        let portBox = Box<UInt16?>(nil)
        listener.onListening = { portBox.value = $0 }
        // Installed here rather than after the link comes up: the sender starts the moment
        // the handshake completes, so a handler attached afterwards misses the offer and the
        // first chunks. Assigning it from inside onLinkReady — which runs on the link's own
        // queue — means it is in place before any message is delivered.
        let accepted = Box<SecureLink?>(nil)
        let incoming = Box<((Message) -> Void)?>(nil)
        listener.onLinkReady = { link, peer in
            directory.note(peer: peer)
            link.onMessage = { message in incoming.value?(message) }
            accepted.value = link
        }
        try listener.start()
        defer { listener.stop() }

        guard Runtime.wait(until: { portBox.value != nil }, timeout: 5), let port = portBox.value else {
            record("listener binds a loopback port", false, "listener never came up")
            throw ExitSilently(code: 1)
        }
        record("listener binds a loopback port", true, "127.0.0.1:\(port)")

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                           port: NWEndpoint.Port(rawValue: port)!)

        // 3a. correct key
        let good = try attempt(endpoint: endpoint, psk: code.psk, identity: identity)
        record("handshake with the correct key", good.ready,
               good.ready ? good.tls : (good.error ?? "no reason given"))
        if let rtt = good.rtt {
            record("ping/pong over the encrypted link", true, String(format: "%.2f ms round trip", rtt))
        } else {
            record("ping/pong over the encrypted link", false, "no pong received")
        }
        record("pairing pinned to this device on first use",
               directory.snapshot.pairings.first?.peerDeviceID == identity.deviceID,
               directory.snapshot.pairings.first?.statusText ?? "")

        // 3b. wrong key — must be refused by TLS, before any application byte is read
        let wrong = try attempt(endpoint: endpoint, psk: Crypto.randomBytes(32), identity: identity)
        record("handshake with a wrong key is refused", !wrong.ready,
               wrong.ready ? "ACCEPTED — THIS IS A BUG" : "rejected at the TLS layer")

        // 3c. right key, unrecognised device — must be refused by the allowlist
        let impostorIdentity = Identity(deviceID: DeviceID(),
                                        deviceName: "Impostor",
                                        createdAt: Date())
        let impostor = try attempt(endpoint: endpoint, psk: code.psk, identity: impostorIdentity)
        record("a different Mac reusing the same key is refused", !impostor.ready,
               impostor.ready ? "ACCEPTED — THIS IS A BUG" : "rejected by the device allowlist")

        // ---- 4. Files over that same link -------------------------------------
        out()
        out(Style.bold("Dragged files (loopback)"))
        try checkFileTransfer(endpoint: endpoint, psk: code.psk, identity: identity,
                              accepted: accepted, incoming: incoming, record: record)

        // ---- summary ----------------------------------------------------------
        out()
        let failed = checks.filter { !$0.passed }
        if failed.isEmpty {
            out(Style.green(Style.bold("  All \(checks.count) checks passed.")))
            out(Style.dim("  Milestone 1 is working on this Mac. Pair it with the other one next."))
        } else {
            out(Style.red(Style.bold("  \(failed.count) of \(checks.count) checks failed:")))
            for f in failed { out("    · \(f.name) — \(f.detail)") }
            throw ExitSilently(code: 1)
        }
    }

    /// Sends a real file over a real link and checks that it arrives byte for byte.
    ///
    /// Everything about carrying files is here: chunking, ordering, the name landing
    /// uniquely, and the bytes surviving the round trip — all of it checkable on one Mac,
    /// which is the only kind of check that is worth having before two are involved.
    private static func checkFileTransfer(endpoint: NWEndpoint, psk: Data, identity: Identity,
                                          accepted: Box<SecureLink?>,
                                          incoming: Box<((Message) -> Void)?>,
                                          record: (String, Bool, String) -> Void) throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory
            .appendingPathComponent("edge-selftest-\(UUID().uuidString)", isDirectory: true)
        let inbox = workspace.appendingPathComponent("inbox", isDirectory: true)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }

        // Three chunks and a bit, so ordering across chunk boundaries is actually exercised.
        let contents = Crypto.randomBytes(FileLimits.chunkBytes * 3 + 1234)
        let source = workspace.appendingPathComponent("selftest payload.bin")
        try contents.write(to: source)

        accepted.value = nil
        let landed = Box<[URL]>([])
        let failure = Box<String?>(nil)

        let receiver = FileReceiver(directory: inbox)
        receiver.onReceived = { urls, _ in landed.value = urls }
        receiver.onFailed = { failure.value = $0 }
        incoming.value = { receiver.handle($0, from: "selftest") }
        defer { incoming.value = nil }

        let link = LinkConnector.connect(to: endpoint, psk: psk, identity: identity,
                                         localRole: .host, handshakeTimeout: 4)
        let finished = Box<Bool>(false)
        let sender = FileSender(link: link)
        sender.onFinished = { reason in
            if let reason { failure.value = reason }
            finished.value = true
        }
        link.onReady = { _ in sender.start(urls: [source]) }
        link.onClose = { error in
            if let error { failure.value = error.localizedDescription }
            finished.value = true
        }
        link.start()

        guard Runtime.wait(until: { accepted.value != nil }, timeout: 8) else {
            record("a file crosses an encrypted link", false, "the link never came up")
            return
        }

        let arrived = Runtime.wait(until: { !landed.value.isEmpty || failure.value != nil },
                                   timeout: 30)
        _ = Runtime.wait(until: { finished.value }, timeout: 5)
        link.close(reason: "selftest done")
        Thread.sleep(forTimeInterval: 0.15)

        guard arrived, let delivered = landed.value.first else {
            record("a file crosses an encrypted link", false,
                   failure.value ?? "nothing arrived within 30 seconds")
            return
        }
        record("a file crosses an encrypted link", true,
               "\(contents.count) bytes in \(contents.count / FileLimits.chunkBytes + 1) chunks")
        record("it arrives under its own name", delivered.lastPathComponent == source.lastPathComponent,
               delivered.lastPathComponent)
        let received = (try? Data(contentsOf: delivered)) ?? Data()
        record("every byte survives the trip", received == contents,
               received.count == contents.count ? "identical" : "\(received.count) of \(contents.count) bytes")
    }

    private struct Attempt {
        var ready = false
        var tls = ""
        var rtt: Double?
        var error: String?
    }

    private static func attempt(endpoint: NWEndpoint, psk: Data, identity: Identity) throws -> Attempt {
        let box = Box<Attempt>(Attempt())
        let settled = Box<Bool>(false)

        let link = LinkConnector.connect(to: endpoint, psk: psk, identity: identity,
                                         localRole: .host, handshakeTimeout: 4)

        link.onReady = { peer in
            box.mutate { $0.ready = true; $0.tls = peer.tlsDescription }
            link.send(.ping(seq: 1, sentAt: DispatchTime.now().uptimeNanoseconds))
        }
        link.onMessage = { message in
            if case let .pong(_, sentAt) = message {
                box.mutate { $0.rtt = Double(DispatchTime.now().uptimeNanoseconds &- sentAt) / 1e6 }
                settled.value = true
            }
        }
        link.onClose = { error in
            box.mutate { $0.error = error?.localizedDescription }
            settled.value = true
        }
        link.start()

        _ = Runtime.wait(until: { settled.value }, timeout: 8)
        link.close(reason: "selftest done")
        // Let the close propagate before the next attempt reuses the listener.
        Thread.sleep(forTimeInterval: 0.15)
        return box.value
    }
}

/// Small synchronised box so the self-test can observe callbacks from the network queues.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) { storage = initial }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); body(&storage); lock.unlock()
    }
}
