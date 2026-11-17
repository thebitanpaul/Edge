import Foundation
import Network
import CryptoKit

/// Pairing two Macs without anybody typing a code.
///
/// Typing a code has one failure that no amount of care prevents: it is two separate manual
/// actions, and nothing tells you they agreed until a connection succeeds much later. Re-pair
/// one Mac and not the other and the two keys silently diverge — which looks exactly like a
/// mistyped code, so the natural response is to re-pair again, which recreates the problem.
///
/// Here both Macs run the same action, generate an ephemeral X25519 key pair, exchange public
/// keys and derive the same shared secret. Neither one can end up with a key the other does
/// not have: either both save the same secret or neither saves anything.
///
/// An eavesdropper learns nothing — that is Diffie-Hellman. Someone actively in the middle
/// could substitute their own keys, so both Macs show a six-digit number derived from the
/// exchange and you confirm they match. A machine in the middle would have to produce the
/// same six digits on both sides by chance.
public enum NetworkPairing {
    public static let serviceType = "_continuous-pair._tcp"
    /// Long enough to walk to the other Mac, short enough not to sit open all day.
    public static let window: TimeInterval = 180

    public struct Outcome: Sendable {
        public let psk: Data
        public let peerName: String
        /// The digits the person compared.
        public let verification: String
    }

    public enum Failure: LocalizedError {
        case noPeerFound
        case cancelled
        case refusedByPeer
        case protocolError(String)

        public var errorDescription: String? {
            switch self {
            case .noPeerFound:
                return "no other Mac is waiting to pair — start pairing on it too, within a couple of minutes"
            case .cancelled:
                return "pairing was cancelled"
            case .refusedByPeer:
                return "the other Mac did not confirm the number"
            case .protocolError(let detail):
                return "pairing failed: \(detail)"
            }
        }
    }

    // MARK: - The number people compare

    /// Six digits from both public keys, in a fixed order so both Macs compute the same thing
    /// regardless of which one dialled.
    static func verificationDigits(_ a: Curve25519.KeyAgreement.PublicKey,
                                   _ b: Curve25519.KeyAgreement.PublicKey) -> String {
        let keys = [a.rawRepresentation, b.rawRepresentation].sorted { lhs, rhs in
            lhs.lexicographicallyPrecedes(rhs)
        }
        var input = Data("continuous/v1/pair-verification".utf8)
        keys.forEach { input.append($0) }
        let digest = Array(SHA256.hash(data: input))
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06u", value)
    }

    static func derivePSK(from secret: SharedSecret) -> Data {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                       salt: Crypto.pskSalt,
                                       sharedInfo: Data("pre-shared-key".utf8),
                                       outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    // MARK: - Wire format
    //
    // Deliberately tiny and self-contained: [u8 version][u8 type][payload]. This runs before
    // there is any shared key, so it cannot use the main protocol, and keeping it separate
    // means the main protocol is never reachable without one.

    enum Tag: UInt8 { case hello = 1, confirm = 2, reject = 3 }
    static let version: UInt8 = 1

    static func encodeHello(publicKey: Curve25519.KeyAgreement.PublicKey, name: String) -> Data {
        var w = BinaryWriter(capacity: 96)
        w.u8(version)
        w.u8(Tag.hello.rawValue)
        w.blob(publicKey.rawRepresentation)
        w.string(name)
        return w.data
    }

    static func decodeHello(_ data: Data) throws -> (Curve25519.KeyAgreement.PublicKey, String) {
        var r = BinaryReader(data)
        guard let v = try? r.u8(), v == version else {
            throw Failure.protocolError("the other Mac is running a different version")
        }
        guard let tag = try? r.u8(), tag == Tag.hello.rawValue else {
            throw Failure.protocolError("unexpected message")
        }
        guard let raw = try? r.blob(32),
              let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else {
            throw Failure.protocolError("malformed key")
        }
        let name = (try? r.string()) ?? "the other Mac"
        return (key, name)
    }

    static func encode(_ tag: Tag) -> Data {
        var w = BinaryWriter(capacity: 2)
        w.u8(version)
        w.u8(tag.rawValue)
        return w.data
    }
}

/// Runs one pairing attempt: advertises, looks for a Mac already advertising, and takes
/// whichever role falls out of that.
///
/// Both Macs run exactly this, so there is no "which one goes first" for anyone to get wrong.
/// If it finds a waiting Mac it dials; otherwise it waits to be dialled.
public final class NetworkPairingSession {
    public enum Progress: Sendable {
        case waiting                      // advertising, nothing found yet
        case found(String)                // talking to a Mac
        case verify(digits: String, peer: String)
        case done(NetworkPairing.Outcome)
        case failed(String)
    }

    private let identity: Identity
    private let link: LinkPreference
    private let queue = DispatchQueue(label: "app.continuous.pairing")

    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private var listener: NWListener?
    private var discovery: Discovery?
    private var connection: NWConnection?
    private var finished = false

    /// Set once both sides have shown the number; call `confirm(_:)` to answer.
    private var pending: (secret: SharedSecret, digits: String, peer: String)?
    private var localConfirmed = false
    private var peerConfirmed = false

    /// Cleared after the well-known port turns out to be busy.
    private var useWellKnownPort = true

    /// Listen on the well-known port as well, so the other Mac can be told an address.
    public var acceptsDirectDial = true

    public var onProgress: ((Progress) -> Void)?

    /// An address to dial instead of waiting to find one. For networks where discovery is
    /// blocked — the only situation a typed code was ever needed for.
    private let directAddress: String?

    public init(identity: Identity, link: LinkPreference = .auto, address: String? = nil) {
        self.identity = identity
        self.link = link
        self.directAddress = address
    }

    // MARK: - Lifecycle

    public func start() {
        startListening()
        if let directAddress {
            dialDirectly(directAddress)
        } else {
            startBrowsing()
        }
        report(.waiting)

        queue.asyncAfter(deadline: .now() + NetworkPairing.window) { [weak self] in
            guard let self, !self.finished, self.pending == nil else { return }
            self.fail(NetworkPairing.Failure.noPeerFound.localizedDescription)
        }
    }

    public func cancel() {
        guard !finished else { return }
        finished = true
        send(NetworkPairing.encode(.reject))
        teardown()
    }

    /// Answers the number the person was shown. Both Macs must say yes.
    public func confirm(_ matches: Bool) {
        queue.async { [weak self] in
            guard let self, !self.finished, self.pending != nil else { return }
            guard matches else {
                self.send(NetworkPairing.encode(.reject))
                self.fail(NetworkPairing.Failure.cancelled.localizedDescription)
                return
            }
            self.localConfirmed = true
            self.send(NetworkPairing.encode(.confirm))
            self.completeIfReady()
        }
    }

    private func teardown() {
        listener?.cancel(); listener = nil
        discovery?.stop(); discovery = nil
        connection?.cancel(); connection = nil
    }

    private func report(_ progress: Progress) {
        DispatchQueue.main.async { self.onProgress?(progress) }
    }

    private func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        teardown()
        report(.failed(reason))
    }

    // MARK: - Finding each other

    private func startListening() {
        let parameters = NWParameters.tcp
        // Deliberately not allowLocalEndpointReuse. With it, two instances both bind the
        // well-known port and both advertise an identical service — same name, type, port —
        // which Bonjour collapses into one record, so each sees only itself. Letting the
        // second bind fail is what makes it take a different port and become visible.
        parameters.includePeerToPeer = true
        if let required = link.interfaceType { parameters.requiredInterfaceType = required }

        // An ephemeral port, not a fixed one. Bonjour carries whatever port is bound, so
        // nothing needs to agree on a number in advance — and two instances on one machine
        // cannot collide, which is exactly the case a fixed port made impossible to test.
        // Prefer the well-known port, because an address typed by hand carries no port
        // number with it. If it is taken, fall back to any free one — being discoverable
        // matters more than being directly dialable.
        //
        // The fallback has to be driven from the state handler rather than from a failed
        // initialiser: binding an occupied port succeeds here and only fails later, when the
        // listener starts. Treating the constructor's success as the answer meant the second
        // instance on a machine gave up instead of moving aside.
        let wanted = (useWellKnownPort && acceptsDirectDial)
            ? (NWEndpoint.Port(rawValue: 52779) ?? .any) : .any
        guard let listener = try? NWListener(using: parameters, on: wanted) else {
            fail("could not open a pairing port")
            return
        }
        var txt = NWTXTRecord()
        txt["name"] = identity.deviceName
        // The device id, not the name: two Macs can share a name, and a Mac must be able to
        // tell its own advertisement from somebody else's.
        txt["id"] = identity.deviceID.compact
        listener.service = NWListener.Service(name: identity.deviceName,
                                              type: NetworkPairing.serviceType,
                                              txtRecord: txt.data)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            guard case let .failed(error) = state else { return }
            if self.useWellKnownPort {
                Log.debug("pairing port busy, taking another: \(error.localizedDescription)")
                self.useWellKnownPort = false
                self.listener?.cancel()
                self.listener = nil
                self.startListening()
                return
            }
            self.fail("could not advertise for pairing: \(error.localizedDescription)")
        }
        listener.newConnectionHandler = { [weak self] incoming in
            Log.debug("a Mac is dialling us to pair")
            self?.adopt(incoming, asInitiator: false)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func startBrowsing() {
        let discovery = Discovery(serviceType: NetworkPairing.serviceType)
        discovery.onChange = { [weak self] peers in
            guard let self, self.connection == nil, !self.finished else { return }
            // Anything but ourselves, by device id. Comparing names looks equivalent and is
            // not: two Macs can be called the same thing, and a Mac whose own advertisement
            // it cannot recognise will happily pair with itself.
            guard let peer = peers.first(where: { $0.deviceID != self.identity.deviceID })
            else { return }
            Log.debug("found a Mac waiting to pair: \(peer.serviceName)")
            self.queue.async {
                guard self.connection == nil, !self.finished else { return }
                let parameters = NWParameters.tcp
                parameters.includePeerToPeer = true
                if let required = self.link.interfaceType {
                    parameters.requiredInterfaceType = required
                }
                self.adopt(NWConnection(to: peer.endpoint, using: parameters), asInitiator: true)
            }
        }
        discovery.start()
        self.discovery = discovery
    }

    /// Dials a Mac at a known address rather than waiting to discover one.
    private func dialDirectly(_ address: String) {
        guard let endpoint = try? LinkConnector.parseEndpoint(address, defaultPort: 52779) else {
            fail("'\(address)' is not an address this can dial")
            return
        }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let required = link.interfaceType { parameters.requiredInterfaceType = required }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.connection == nil, !self.finished else { return }
            self.adopt(NWConnection(to: endpoint, using: parameters), asInitiator: true)
        }
    }

    // MARK: - The exchange

    private func adopt(_ connection: NWConnection, asInitiator: Bool) {
        guard self.connection == nil else { connection.cancel(); return }
        self.connection = connection
        // Only one pairing at a time: stop advertising so a third Mac cannot join in.
        listener?.cancel(); listener = nil
        discovery?.stop(); discovery = nil

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Log.debug("pairing connection: \(state)")
            switch state {
            case .ready:
                self.receive()
                self.sendHello()
            case .failed(let error):
                self.fail("could not reach the other Mac: \(error.localizedDescription)")
            case .waiting(let error):
                // Not fatal on its own — it retries — but it is the state a connection sits
                // in for ever when there is no usable route, so say so rather than hang.
                Log.debug("pairing connection waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)

        // Both sides say hello once the connection is up; whoever dialled is not special.
        // The exchange is symmetric, so there is no first mover to get wrong.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.finished, self.pending == nil else { return }
            self.fail("the other Mac did not answer")
        }
    }

    private func sendHello() {
        send(NetworkPairing.encodeHello(publicKey: privateKey.publicKey,
                                        name: identity.deviceName))
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 2, maximumLength: 4096) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.fail("the connection dropped: \(error.localizedDescription)")
                return
            }
            if let data, !data.isEmpty { self.handle(data) }
            if isComplete {
                if !self.finished && self.pending == nil {
                    self.fail("the other Mac closed the connection")
                }
                return
            }
            if !self.finished { self.receive() }
        }
    }

    private func handle(_ data: Data) {
        guard data.count >= 2, let tag = NetworkPairing.Tag(rawValue: data[data.startIndex + 1])
        else { return }

        switch tag {
        case .hello:
            guard pending == nil else { return }
            do {
                let (peerKey, peerName) = try NetworkPairing.decodeHello(data)
                let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
                let digits = NetworkPairing.verificationDigits(privateKey.publicKey, peerKey)
                pending = (secret, digits, peerName)
                report(.found(peerName))
                report(.verify(digits: digits, peer: peerName))
            } catch {
                fail(error.localizedDescription)
            }
        case .confirm:
            peerConfirmed = true
            completeIfReady()
        case .reject:
            fail(NetworkPairing.Failure.refusedByPeer.localizedDescription)
        }
    }

    /// Saves nothing until both Macs have said the numbers match.
    private func completeIfReady() {
        guard !finished, localConfirmed, peerConfirmed, let pending else { return }
        finished = true
        let outcome = NetworkPairing.Outcome(psk: NetworkPairing.derivePSK(from: pending.secret),
                                             peerName: pending.peer,
                                             verification: pending.digits)
        // Let the other side's confirmation drain before dropping the connection.
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.teardown() }
        report(.done(outcome))
    }
}
