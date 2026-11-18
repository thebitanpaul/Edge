import Foundation
import Network

/// Accepts incoming links. Runs on the Mac that lends its screen.
public final class LinkListener {
    public struct Options: Sendable {
        public var port: UInt16
        public var requireLocalNetwork: Bool
        public var bonjourName: String?
        public var handshakeTimeout: TimeInterval
        /// Bind to loopback only. Used by `selftest` so the check never touches the network.
        public var loopbackOnly: Bool
        /// Which links to accept on. Leave as `.auto` unless you have a reason not to:
        /// restricting it makes this Mac unreachable from one that prefers another link.
        public var link: LinkPreference

        public init(port: UInt16, requireLocalNetwork: Bool = true,
                    bonjourName: String? = nil, handshakeTimeout: TimeInterval = 10,
                    loopbackOnly: Bool = false,
                    link: LinkPreference = .auto) {
            self.port = port
            self.requireLocalNetwork = requireLocalNetwork
            self.bonjourName = bonjourName
            self.handshakeTimeout = handshakeTimeout
            self.loopbackOnly = loopbackOnly
            self.link = link
        }
    }

    public static let bonjourServiceType = "_edge._tcp"

    private let identity: Identity
    private let localRole: Role
    private let capabilities: Capabilities
    private let options: Options
    private let keys: [PSKEntry]
    private let resolvePSK: @Sendable (Data) -> Data?
    private let authorizePeer: @Sendable (DeviceID, Data) -> Bool
    private let queue = DispatchQueue(label: "app.edge.listener")

    private var listener: NWListener?
    private var links: [ObjectIdentifier: SecureLink] = [:]

    public var onListening: ((UInt16) -> Void)?
    public var onLinkReady: ((SecureLink, PeerInfo) -> Void)?
    /// Which link closed, by identity, so a late close from a link that has already been
    /// replaced can be told apart from the current one going down.
    public var onLinkClosed: ((ObjectIdentifier, PeerInfo?, Error?) -> Void)?
    public var onRejected: ((String, String) -> Void)?
    public var onFailure: ((Error) -> Void)?

    public init(identity: Identity,
                localRole: Role,
                capabilities: Capabilities = .baseline,
                options: Options,
                keys: [PSKEntry],
                resolvePSK: @escaping @Sendable (Data) -> Data?,
                authorizePeer: @escaping @Sendable (DeviceID, Data) -> Bool) {
        self.identity = identity
        self.localRole = localRole
        self.capabilities = capabilities
        self.options = options
        self.keys = keys
        self.resolvePSK = resolvePSK
        self.authorizePeer = authorizePeer
    }

    public func start() throws {
        let params = TLSConfig.parameters(keys: keys, link: options.link)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = !options.loopbackOnly
        if options.loopbackOnly {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: options.port) ?? .any)
        }

        let listener: NWListener
        if options.port == 0 {
            listener = try NWListener(using: params)
        } else {
            guard let port = NWEndpoint.Port(rawValue: options.port) else {
                throw EdgeError.invalidArgument("invalid port \(options.port)")
            }
            listener = try NWListener(using: params, on: port)
        }

        if let name = options.bonjourName {
            var txt = NWTXTRecord()
            txt["id"] = identity.deviceID.compact
            txt["v"] = String(Wire.protocolVersion)
            txt["role"] = localRole.description
            // Our own addresses, so the other Mac can pick the one it wants rather than
            // taking whatever Bonjour resolution happens to try first. This is how a cable
            // gets used: a Thunderbolt link carries only a link-local address and no route,
            // so Network.framework does not list its interface at all and cannot be asked
            // to prefer it — but it will happily connect to the address.
            txt["addrs"] = NetworkAddress.localAddresses().joined(separator: ",")
            txt["port"] = String(self.listener?.port?.rawValue ?? options.port)
            listener.service = NWListener.Service(name: name,
                                                  type: Self.bonjourServiceType,
                                                  txtRecord: txt.data)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let bound = self.listener?.port?.rawValue ?? self.options.port
                self.republishService(port: bound)
                self.onListening?(bound)
            case .failed(let error):
                Log.error("listener failed: \(error)")
                self.onFailure?(error)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    /// Re-advertises once the real port is known, so the TXT record can carry it.
    private func republishService(port: UInt16) {
        guard let name = options.bonjourName, let listener else { return }
        var txt = NWTXTRecord()
        txt["id"] = identity.deviceID.compact
        txt["v"] = String(Wire.protocolVersion)
        txt["role"] = localRole.description
        txt["addrs"] = NetworkAddress.localAddresses().joined(separator: ",")
        txt["port"] = String(port)
        listener.service = NWListener.Service(name: name, type: Self.bonjourServiceType,
                                              txtRecord: txt.data)
    }

    public func stop() {
        queue.sync {
            for link in links.values { link.close(reason: "listener shutting down") }
            links.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        let described = NetworkAddress.describe(connection.endpoint)

        if options.requireLocalNetwork && !NetworkAddress.isAcceptablePeer(connection.endpoint) {
            onRejected?(described, "not a private address and not on a subnet this Mac is attached to")
            connection.cancel()
            return
        }

        let link = SecureLink(connection: connection,
                              role: .responder,
                              identity: identity,
                              localRole: localRole,
                              capabilities: capabilities,
                              outboundPSK: nil,
                              resolvePSK: resolvePSK,
                              authorizePeer: authorizePeer,
                              handshakeTimeout: options.handshakeTimeout,
                              queue: queue)
        let token = ObjectIdentifier(link)
        links[token] = link

        link.onReady = { [weak self, weak link] peer in
            guard let self, let link else { return }
            self.onLinkReady?(link, peer)
        }
        link.onClose = { [weak self, weak link] error in
            guard let self else { return }
            self.queue.async {
                self.links[token] = nil
                // A link that never reached `ready` has no peer. Those are routine: a client
                // dialling a Bonjour name opens several candidate connections and drops the
                // ones that lose the race. Reporting each as a failure would be pure noise.
                if let peer = link?.peer {
                    self.onLinkClosed?(token, peer, error)
                } else if let error {
                    Log.debug("discarded an unestablished connection from \(described): \(error.localizedDescription)")
                }
            }
        }
        link.start()
    }
}
