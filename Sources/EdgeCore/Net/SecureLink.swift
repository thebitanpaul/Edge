import Foundation
import Network

public struct PeerInfo: Sendable {
    public var deviceID: DeviceID
    public var name: String
    /// The peer's mDNS hostname, so we can find it again without Bonjour browsing.
    public var hostName: String = ""
    public var role: Role
    public var capabilities: Capabilities
    public var endpoint: String
    public var tlsDescription: String
    /// Set on the responder side: identifies which pre-shared key the peer authenticated with.
    public var keyID: Data
}

/// One authenticated, encrypted, message-framed connection to the other Mac.
///
/// Two layers of authentication sit on top of each other:
///
/// 1. **TLS 1.3 with an external pre-shared key.** An attacker without the key cannot finish
///    the handshake, so no application code ever sees their bytes.
/// 2. **A mutual HMAC challenge/response** over nonces contributed by both sides. This is
///    belt-and-braces against a flaw in the layer below, and it is also what binds the
///    connection to a specific *device id* rather than merely to the key.
public final class SecureLink {
    public enum HandshakeRole: Sendable {
        case initiator   // dialled out; knows exactly which key it is using
        case responder   // accepted a connection; must look the key up by its identifier
    }

    private enum Phase {
        case connecting
        case awaitingHello
        case awaitingHelloAck
        case awaitingAuthProof
        case awaitingReady
        case ready
        case closed
    }

    public let role: HandshakeRole
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let identity: Identity
    private let localRole: Role
    private let capabilities: Capabilities
    private let handshakeTimeout: TimeInterval

    /// Responder-side lookup from the public key id offered by the peer to the matching PSK.
    private let resolvePSK: @Sendable (Data) -> Data?
    /// Initiator-side: the single key we dialled with.
    private let outboundPSK: Data?
    /// Responder-side: optional allowlist check, run once the peer's device id is authenticated.
    private let authorizePeer: @Sendable (DeviceID, Data) -> Bool

    private var phase: Phase = .connecting
    private var localNonce = Data()
    private var remoteNonce = Data()
    private var sessionAuthKey = Data()
    private var negotiatedKeyID = Data()
    private var pendingPeer: (id: DeviceID, name: String, host: String, role: Role, caps: Capabilities)?
    private var timeoutWork: DispatchWorkItem?
    private var didFinish = false

    /// Frames handed to the socket but not yet acknowledged by it.
    private var inFlightSends = 0
    /// The newest pointer position that could not go out immediately.
    private var deferredMove: Message?
    /// How many stale positions were dropped — a measure of how far behind the link is.
    public private(set) var coalescedMoves = 0
    /// Two is enough to keep the socket busy without letting a queue form behind it.
    private static let maxInFlightSends = 2

    public var onReady: ((PeerInfo) -> Void)?
    public var onMessage: ((Message) -> Void)?
    public var onClose: ((Error?) -> Void)?

    public private(set) var peer: PeerInfo?

    public init(connection: NWConnection,
                role: HandshakeRole,
                identity: Identity,
                localRole: Role,
                capabilities: Capabilities = .baseline,
                outboundPSK: Data? = nil,
                resolvePSK: @escaping @Sendable (Data) -> Data? = { _ in nil },
                authorizePeer: @escaping @Sendable (DeviceID, Data) -> Bool = { _, _ in true },
                handshakeTimeout: TimeInterval = 10,
                queue: DispatchQueue = DispatchQueue(label: "app.edge.link")) {
        self.connection = connection
        self.role = role
        self.identity = identity
        self.localRole = localRole
        self.capabilities = capabilities
        self.outboundPSK = outboundPSK
        self.resolvePSK = resolvePSK
        self.authorizePeer = authorizePeer
        self.handshakeTimeout = handshakeTimeout
        self.queue = queue
    }

    // MARK: - Lifecycle

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Check what was actually negotiated before a single application byte moves.
                if let problem = TLSConfig.verifyNegotiation(self.connection) {
                    self.finish(error: EdgeError.handshakeFailed(problem))
                    return
                }
                Log.debug("tls established with \(NetworkAddress.describe(self.connection.currentPath?.remoteEndpoint)) — \(TLSConfig.describeNegotiation(self.connection))")
                self.beginHandshake()
            case .failed(let error):
                self.finish(error: EdgeError.transport(self.explain(error)))
            case .cancelled:
                self.finish(error: nil)
            case .waiting(let error):
                Log.debug("link waiting: \(self.explain(error))")
            default:
                break
            }
        }
        armTimeout()
        receiveLoop()
        connection.start(queue: queue)
    }

    /// NWError's default description is unhelpful for the two failures users actually hit.
    private func explain(_ error: NWError) -> String {
        if case .tls(let status) = error {
            // -9864 is errSSLUnknownPSKIdentity, and it is worth naming precisely: it means
            // the other Mac has no key matching the one offered. The commonest cause is not a
            // mistyped code but a listener that was started before the pairing was created
            // and is still holding the key set it read at start-up.
            if status == -9864 {
                return "the other Mac does not recognise this pairing key.\n"
                    + "  · if it was already running when you paired, restart it over there —\n"
                    + "    a session reads the keys it will accept when it starts\n"
                    + "  · otherwise the two Macs hold different pairings; pair them again\n"
                    + "    (Devices ▸ Connect to a nearby Mac…)"
            }
            return "TLS handshake failed (OSStatus \(status)) — the two Macs may hold different pairings; pair them again"
        }
        if case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED: return "connection refused — is `edge listen` running on the other Mac?"
            case .ETIMEDOUT:    return "connection timed out — check that both Macs are on the same network"
            case .EHOSTUNREACH, .ENETUNREACH: return "host unreachable — check the address and network"
            case .ECONNRESET:   return "connection reset by peer"
            default: break
            }
        }
        return "\(error)"
    }

    public func close(reason: String = "closing") {
        queue.async { [weak self] in
            guard let self, self.phase != .closed else { return }
            if self.phase == .ready {
                self.transmit(.bye(reason: reason))
            }
            self.finish(error: nil)
        }
    }

    private func finish(error: Error?) {
        guard !didFinish else { return }
        didFinish = true
        phase = .closed
        timeoutWork?.cancel()
        timeoutWork = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let closed = onClose
        // Callers' handlers routinely capture the link itself. Released here, a closed link
        // and everything those handlers hold go away with it; kept, every reconnection
        // attempt while the other Mac is unreachable leaked one link and its helpers.
        onReady = nil
        onMessage = nil
        onClose = nil
        closed?(error)
    }

    private func armTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase != .ready, self.phase != .closed else { return }
            self.finish(error: EdgeError.timedOut("handshake did not complete within \(Int(self.handshakeTimeout))s"))
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + handshakeTimeout, execute: work)
    }

    // MARK: - Sending

    public func send(_ message: Message) {
        queue.async { [weak self] in
            guard let self, self.phase == .ready else { return }
            self.enqueue(message)
        }
    }

    /// Sends, and calls back once the socket has taken the frame — or once, with `false`, if
    /// the link went away first.
    ///
    /// This is what paces a file transfer. Handing a whole file to the socket at once would
    /// put megabytes in front of every pointer movement that follows, so each chunk waits for
    /// the one before it. Pointer moves are coalesced rather than queued, so they still
    /// overtake a transfer in progress and the cursor keeps up while a file is crossing.
    public func send(_ message: Message, whenSent: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, self.phase == .ready else { whenSent(false); return }
            self.transmit(message, then: whenSent)
        }
    }

    /// Keeps at most a couple of frames in flight, and never queues a stale pointer position.
    ///
    /// Pointer moves carry an absolute position, so the moment a newer one exists every older
    /// one is wrong — and handing all of them to the socket does active harm on a slow link.
    /// They pile up ahead of whatever comes next, so the message saying the pointer has left
    /// waits behind a backlog of positions it has already passed through. On a link with a
    /// quarter-second round trip that is the second or two of cursor left behind on the screen
    /// you just left, and it is also why the far pointer replays your movement instead of
    /// following it.
    ///
    /// So a pointer move that cannot go out now replaces the one already waiting rather than
    /// joining a queue behind it. Everything else is sent immediately: there are never enough
    /// clicks or keystrokes to congest anything, and dropping one would be unforgivable.
    private func enqueue(_ message: Message) {
        if case .mouseMove = message, inFlightSends >= Self.maxInFlightSends {
            if deferredMove != nil { coalescedMoves += 1 }
            deferredMove = message
            return
        }
        transmit(message)
    }

    private func transmit(_ message: Message, then whenSent: ((Bool) -> Void)? = nil) {
        let frame = Codec.encodeFrame(message)
        inFlightSends += 1
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            // Runs on the connection's queue, which is this link's queue.
            guard let self else { whenSent?(false); return }
            self.inFlightSends -= 1
            if let error {
                self.finish(error: EdgeError.transport("send failed: \(error)"))
                whenSent?(false)
                return
            }
            if let pending = self.deferredMove {
                self.deferredMove = nil
                self.transmit(pending)
            }
            whenSent?(true)
        })
    }

    // MARK: - Receiving

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.finish(error: EdgeError.transport(self.explain(error))); return }
            guard let data, data.count == 4 else {
                if isComplete { self.finish(error: nil) }
                return
            }
            let length = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            guard length >= 1, length <= Wire.maxFrameSize else {
                self.finish(error: EdgeError.transport("invalid frame length \(length)"))
                return
            }
            self.receiveBody(length: length)
        }
    }

    private func receiveBody(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.finish(error: EdgeError.transport(self.explain(error))); return }
            guard let data, data.count == length else {
                if isComplete { self.finish(error: nil) }
                return
            }
            let rawType = data[data.startIndex]
            let payload = data.subdata(in: (data.startIndex + 1)..<data.endIndex)
            do {
                let message = try Codec.decode(type: rawType, payload: payload)
                self.handle(message)
            } catch {
                Log.warn("dropping undecodable frame: \(error)")
            }
            if self.phase != .closed { self.receiveLoop() }
        }
    }

    // MARK: - Handshake

    private func beginHandshake() {
        switch role {
        case .initiator:
            guard let psk = outboundPSK else {
                finish(error: EdgeError.handshakeFailed("no pre-shared key configured for this peer"))
                return
            }
            sessionAuthKey = Crypto.deriveAuthKey(fromPSK: psk)
            negotiatedKeyID = Crypto.deriveKeyID(fromPSK: psk)
            localNonce = Crypto.randomBytes(Wire.nonceLength)
            phase = .awaitingHelloAck
            transmit(.hello(protocolVersion: Wire.protocolVersion,
                            deviceID: identity.deviceID,
                            deviceName: identity.deviceName,
                            hostName: Identity.localHostName,
                            role: localRole,
                            capabilities: capabilities,
                            nonce: localNonce,
                            keyID: negotiatedKeyID))
        case .responder:
            phase = .awaitingHello
        }
    }

    private func handle(_ message: Message) {
        switch (phase, message) {

        case let (.awaitingHello, .hello(version, peerID, peerName, peerHost, peerRole, peerCaps, peerNonce, keyID)):
            guard version == Wire.protocolVersion else {
                reject(code: 1, "protocol version mismatch: peer speaks v\(version), this build speaks v\(Wire.protocolVersion)")
                return
            }
            guard let psk = resolvePSK(keyID) else {
                // The TLS layer already proved they hold *a* valid key, so this should be
                // unreachable; treat it as a hard failure rather than guessing.
                reject(code: 2, "no pre-shared key matches identifier \(Crypto.hex(keyID))")
                return
            }
            sessionAuthKey = Crypto.deriveAuthKey(fromPSK: psk)
            negotiatedKeyID = keyID
            remoteNonce = peerNonce
            localNonce = Crypto.randomBytes(Wire.nonceLength)
            pendingPeer = (peerID, peerName, peerHost, peerRole, peerCaps)

            let proof = Crypto.proof(authKey: sessionAuthKey, direction: "edge/v1/responder",
                                     clientNonce: remoteNonce, serverNonce: localNonce,
                                     proverDeviceID: identity.deviceID)
            phase = .awaitingAuthProof
            transmit(.helloAck(protocolVersion: Wire.protocolVersion,
                               deviceID: identity.deviceID,
                               deviceName: identity.deviceName,
                               hostName: Identity.localHostName,
                               capabilities: capabilities,
                               nonce: localNonce,
                               proof: proof))

        case let (.awaitingHelloAck, .helloAck(version, peerID, peerName, peerHost, peerCaps, peerNonce, proof)):
            guard version == Wire.protocolVersion else {
                reject(code: 1, "protocol version mismatch: peer speaks v\(version), this build speaks v\(Wire.protocolVersion)")
                return
            }
            remoteNonce = peerNonce
            let expected = Crypto.proof(authKey: sessionAuthKey, direction: "edge/v1/responder",
                                        clientNonce: localNonce, serverNonce: remoteNonce,
                                        proverDeviceID: peerID)
            guard Crypto.constantTimeEquals(expected, proof) else {
                reject(code: 3, "peer failed the challenge — it does not hold the paired key")
                return
            }
            pendingPeer = (peerID, peerName, peerHost, .client, peerCaps)
            let mine = Crypto.proof(authKey: sessionAuthKey, direction: "edge/v1/initiator",
                                    clientNonce: localNonce, serverNonce: remoteNonce,
                                    proverDeviceID: identity.deviceID)
            phase = .awaitingReady
            transmit(.authProof(proof: mine))

        case let (.awaitingAuthProof, .authProof(proof)):
            guard let pending = pendingPeer else {
                reject(code: 4, "internal state error")
                return
            }
            let expected = Crypto.proof(authKey: sessionAuthKey, direction: "edge/v1/initiator",
                                        clientNonce: remoteNonce, serverNonce: localNonce,
                                        proverDeviceID: pending.id)
            guard Crypto.constantTimeEquals(expected, proof) else {
                reject(code: 3, "peer failed the challenge — it does not hold the paired key")
                return
            }
            guard authorizePeer(pending.id, negotiatedKeyID) else {
                reject(code: 5, "device \(pending.id.short) is not on this Mac's allowlist")
                return
            }
            transmit(.ready)
            becomeReady()

        case (.awaitingReady, .ready):
            becomeReady()

        case let (_, .failure(code, text)):
            finish(error: EdgeError.handshakeFailed("peer rejected the link (code \(code)): \(text)"))

        case let (_, .bye(reason)):
            Log.info("peer closed the link: \(reason)")
            finish(error: nil)

        case let (.ready, .ping(seq, sentAt)):
            transmit(.pong(seq: seq, sentAt: sentAt))
            onMessage?(message)

        case (.ready, _):
            onMessage?(message)

        default:
            Log.warn("ignoring unexpected \(message.type) during handshake")
        }
    }

    private func becomeReady() {
        guard let pending = pendingPeer else { return }
        timeoutWork?.cancel()
        timeoutWork = nil
        phase = .ready
        let info = PeerInfo(deviceID: pending.id,
                            name: pending.name,
                            hostName: pending.host,
                            role: pending.role,
                            capabilities: pending.caps,
                            endpoint: NetworkAddress.describe(connection.currentPath?.remoteEndpoint ?? connection.endpoint),
                            tlsDescription: TLSConfig.describeNegotiation(connection),
                            keyID: negotiatedKeyID)
        peer = info
        onReady?(info)
    }

    private func reject(code: UInt16, _ text: String) {
        transmit(.failure(code: code, message: text))
        // Give the frame a moment to drain before tearing the socket down.
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.finish(error: EdgeError.handshakeFailed(text))
        }
    }
}
