import Foundation
import Network

public struct DiscoveredPeer: Sendable, Hashable {
    public var serviceName: String
    public var deviceID: DeviceID?
    public var role: String?
    public var endpoint: NWEndpoint
    /// Addresses the Mac advertised for itself, and the port it is listening on.
    public var advertisedAddresses: [String] = []
    public var advertisedPort: UInt16?

    /// The address of a direct cable, if one was advertised.
    public var cableAddress: String? {
        advertisedAddresses.first(where: NetworkAddress.isLinkLocalIPv4)
    }

    /// Where to dial, for the kind of link wanted. `nil` means "nothing suitable".
    ///
    /// Picking an address rather than an interface is not a preference, it is a necessity:
    /// a cable between two Macs has no route, so Network.framework never lists its interface
    /// and cannot be asked to prefer it. The address, however, works perfectly.
    public func endpoint(preferring link: LinkPreference) -> NWEndpoint? {
        if let cable = cableAddress, link.prefersCable, let port = advertisedPort,
           let nwPort = NWEndpoint.Port(rawValue: port) {
            return .hostPort(host: NWEndpoint.Host(cable), port: nwPort)
        }
        if link.requiresCable { return nil }
        return endpoint
    }

    public var displayName: String {
        if let deviceID { return "\(serviceName)  [\(deviceID.short)]" }
        return serviceName
    }
}

///
/// Discovery is a convenience only: it never conveys trust. A discovered Mac still has to
/// pass the pre-shared-key handshake, and an attacker advertising a fake service gains nothing.
public enum PeerSelection {
    /// Picks which discovered Mac to dial for a given pairing.
    ///
    /// The case that matters is a pairing that has never connected. It has no peer device id
    /// — that is learned *from* the first handshake — so matching on one can only ever fail,
    /// and for a while this meant a fresh pairing could not use discovery at all. You needed
    /// the id to connect and the connection to learn the id.
    ///
    /// For an unbound pairing, then, any Edge Mac that is advertising is worth dialling.
    /// That is safe for the same reason discovery is not a trust boundary anywhere else here:
    /// a machine that does not hold the pairing key cannot finish the TLS handshake, so the
    /// worst a wrong guess costs is one failed connection.
    ///
    /// For a pairing that *is* bound, only the Mac it is pinned to will do — a different one
    /// would be turned away by the allowlist, and dialling it would be noise.
    public static func choose(from peers: [DiscoveredPeer],
                              boundTo peerDeviceID: DeviceID?,
                              excluding localDeviceID: DeviceID?,
                              attempt: Int = 1) -> DiscoveredPeer? {
        // Never dial ourselves: a Mac that is both advertising and dialling would otherwise
        // find its own service and connect to itself.
        let candidates = peers.filter { peer in
            guard let localDeviceID, let id = peer.deviceID else { return true }
            return id != localDeviceID
        }
        guard !candidates.isEmpty else { return nil }

        if let peerDeviceID {
            return candidates.first { $0.deviceID == peerDeviceID }
        }
        // Several unknown Macs: give each one a turn rather than retrying the same one.
        let index = (max(attempt, 1) - 1) % candidates.count
        return candidates[index]
    }
}

/// Bonjour browser for `_edge._tcp`.
public final class Discovery {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "app.edge.discovery")
    private let serviceType: String

    public var onChange: (([DiscoveredPeer]) -> Void)?

    public init(serviceType: String = LinkListener.bonjourServiceType) {
        self.serviceType = serviceType
    }

    public func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let peers: [DiscoveredPeer] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var deviceID: DeviceID?
                var role: String?
                if case let .bonjour(txt) = result.metadata {
                    if let raw = txt["id"] { deviceID = DeviceID(string: raw) }
                    role = txt["role"]
                }
                var addresses: [String] = []
                var advertisedPort: UInt16?
                if case let .bonjour(txt) = result.metadata {
                    addresses = (txt["addrs"] ?? "").split(separator: ",").map(String.init)
                    advertisedPort = (txt["port"]).flatMap { UInt16($0) }
                }
                return DiscoveredPeer(serviceName: name, deviceID: deviceID,
                                      role: role, endpoint: result.endpoint,
                                      advertisedAddresses: addresses,
                                      advertisedPort: advertisedPort)
            }
            Log.debug("browse(\(self.serviceType)): \(peers.count) result(s) — "
                      + peers.map { "\($0.serviceName)[\($0.deviceID?.short ?? "no id")]" }
                             .joined(separator: ", "))
            self.onChange?(peers.sorted { $0.serviceName < $1.serviceName })
        }

        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let error): Log.warn("discovery failed: \(error)")
            case .ready: Log.debug("browsing for \(self.serviceType)")
            default: break
            }
        }

        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Browses until `match` accepts a result or `timeout` elapses, whichever comes first.
    ///
    /// Returning early matters: when you already know which Mac you want, waiting out a fixed
    /// browse window adds seconds to every connect for no reason.
    public static func first(matching match: @escaping (DiscoveredPeer) -> Bool,
                             timeout: TimeInterval) -> DiscoveredPeer? {
        let discovery = Discovery()
        let lock = NSLock()
        var found: DiscoveredPeer?

        discovery.onChange = { peers in
            lock.lock()
            if found == nil { found = peers.first(where: match) }
            lock.unlock()
        }
        discovery.start()
        defer { discovery.stop() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let hit = found; lock.unlock()
            if let hit { return hit }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock(); defer { lock.unlock() }
        return found
    }

    /// Blocking convenience used by the CLI: browse for `duration`, then return what was seen.
    public static func scan(duration: TimeInterval) -> [DiscoveredPeer] {
        let discovery = Discovery()
        let lock = NSLock()
        var latest: [DiscoveredPeer] = []
        discovery.onChange = { peers in
            lock.lock(); latest = peers; lock.unlock()
        }
        discovery.start()
        Thread.sleep(forTimeInterval: duration)
        discovery.stop()
        lock.lock(); defer { lock.unlock() }
        return latest
    }
}
