import Foundation

/// Keeps both Macs' Wi-Fi radios awake while the pointer is on the far one.
///
/// A laptop's Wi-Fi radio dozes the moment traffic stops, and a packet sent to a dozing radio
/// waits at the router for the next beacon — about a tenth of a second. The pointer's packets
/// stop every time your hand does, so every movement after a pause started late, and the
/// first one after crossing over usually did: a pointer that hesitates, then jumps. The link's
/// own heartbeat measured it: a round trip of 6 ms when the radios were awake and 50–280 ms
/// when they were not.
///
/// So while the pointer is over there, something goes across at least every 25 ms: the input
/// itself while you are moving, and a tiny ping in the gaps. The ping is answered, so both
/// radios — the far one receiving, this one receiving the answer — stay awake. Approaching the
/// edge sends one early, so the far radio is already up when the pointer arrives.
///
/// The pings use a sequence number the heartbeat never does, and every Edge build already
/// answers pings, so this needs nothing from the other Mac.
public final class LinkWarmer {
    /// The ping sequence number reserved for warming. `Heartbeat` skips it.
    public static let pingSeq: UInt32 = 0
    /// Well inside any radio's idle timeout, and a few dozen tiny packets a second at most.
    static let interval: UInt64 = 25_000_000
    /// Stop after this long without input: someone reading, not pointing, is not worth a
    /// radio kept awake. The next movement wakes it again.
    static let idleLimit: UInt64 = 30_000_000_000

    private let queue = DispatchQueue(label: "app.edge.link-warmer", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private weak var link: SecureLink?
    private var lastSent: UInt64 = 0
    private var lastInput: UInt64 = 0

    public init() {}

    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Starts keeping `link` warm, until `stop`.
    public func start(link: SecureLink) {
        let now = Self.now
        lock.lock()
        self.link = link
        lastInput = now
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(25), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        lock.lock()
        self.timer?.cancel()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    public func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        link = nil
        lock.unlock()
    }

    /// Input just went across, which keeps the radios awake by itself; no ping is needed for
    /// another interval.
    public func noteInput() {
        let now = Self.now
        lock.lock()
        lastSent = now
        lastInput = now
        lock.unlock()
    }

    /// One ping now, unless something went across very recently. For the approach to the
    /// edge, before warming proper has started.
    public func nudge(_ link: SecureLink) {
        let now = Self.now
        lock.lock()
        let due = now &- lastSent >= Self.interval
        if due { lastSent = now }
        lock.unlock()
        if due { link.send(.ping(seq: Self.pingSeq, sentAt: now)) }
    }

    private func tick() {
        let now = Self.now
        lock.lock()
        let link = self.link
        let idle = now &- lastInput >= Self.idleLimit
        let due = !idle && now &- lastSent >= Self.interval
        if due { lastSent = now }
        lock.unlock()
        if due, let link { link.send(.ping(seq: Self.pingSeq, sentAt: now)) }
    }
}
