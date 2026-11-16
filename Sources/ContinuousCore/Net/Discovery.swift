import Foundation
import Network

public struct DiscoveredPeer: Sendable, Hashable {
    public var serviceName: String
    public var deviceID: DeviceID?
    public var role: String?
    public var endpoint: NWEndpoint

    public var displayName: String {
        if let deviceID { return "\(serviceName)  [\(deviceID.short)]" }
        return serviceName
    }
}

/// Bonjour browser for `_continuous._tcp`.
///
/// Discovery is a convenience only: it never conveys trust. A discovered Mac still has to
/// pass the pre-shared-key handshake, and an attacker advertising a fake service gains nothing.
public final class Discovery {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "app.continuous.discovery")

    public var onChange: (([DiscoveredPeer]) -> Void)?

    public init() {}

    public func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: LinkListener.bonjourServiceType, domain: nil)
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
                return DiscoveredPeer(serviceName: name, deviceID: deviceID,
                                      role: role, endpoint: result.endpoint)
            }
            self.onChange?(peers.sorted { $0.serviceName < $1.serviceName })
        }

        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { Log.warn("discovery failed: \(error)") }
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
