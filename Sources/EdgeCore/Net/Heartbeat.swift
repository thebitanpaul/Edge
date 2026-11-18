import Foundation

/// Periodic ping/pong on an established link.
///
/// Two jobs: prove the peer is still alive faster than TCP keepalive would, and give the
/// user a real latency number — the single most useful signal when deciding whether to run
/// over Wi-Fi or over a Thunderbolt bridge.
public final class Heartbeat {
    public struct Stats: Sendable {
        public var samples: Int = 0
        public var lastMillis: Double = 0
        public var minMillis: Double = .greatestFiniteMagnitude
        public var maxMillis: Double = 0
        public var meanMillis: Double = 0
        public var lost: Int = 0

        public var summary: String {
            guard samples > 0 else { return "no samples yet" }
            return String(format: "last %.2f ms · min %.2f · mean %.2f · max %.2f · %d sent, %d lost",
                          lastMillis, minMillis, meanMillis, maxMillis, samples + lost, lost)
        }
    }

    private let link: SecureLink
    private let interval: TimeInterval
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "app.edge.heartbeat")
    private var timer: DispatchSourceTimer?
    private var seq: UInt32 = 0
    private var inflight: [UInt32: UInt64] = [:]
    private var stats = Stats()

    public var onSample: ((Double, Stats) -> Void)?
    public var onTimeout: ((UInt32) -> Void)?

    public init(link: SecureLink, interval: TimeInterval = 2, timeout: TimeInterval = 6) {
        self.link = link
        self.interval = interval
        self.timeout = timeout
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        // Anything still unanswered after `timeout` counts as lost.
        for (s, sent) in inflight where Double(now - sent) / 1e9 > timeout {
            inflight[s] = nil
            stats.lost += 1
            onTimeout?(s)
        }
        seq &+= 1
        inflight[seq] = now
        link.send(.ping(seq: seq, sentAt: now))
    }

    /// Feed every message the link delivers; non-pong messages are ignored.
    public func handle(_ message: Message) {
        guard case let .pong(seq, sentAt) = message else { return }
        queue.async {
            guard self.inflight.removeValue(forKey: seq) != nil else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- sentAt) / 1e6
            self.stats.samples += 1
            self.stats.lastMillis = elapsed
            self.stats.minMillis = min(self.stats.minMillis, elapsed)
            self.stats.maxMillis = max(self.stats.maxMillis, elapsed)
            let n = Double(self.stats.samples)
            self.stats.meanMillis += (elapsed - self.stats.meanMillis) / n
            self.onSample?(elapsed, self.stats)
        }
    }

    public var snapshot: Stats { queue.sync { stats } }
}
