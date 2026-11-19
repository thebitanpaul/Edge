import Foundation

/// How unevenly the pointer's updates arrive from the other Mac.
///
/// Each precise pointer move carries the sender's clock. The two Macs' clocks are unrelated,
/// so a single "arrived minus sent" means nothing — but across a stream, the smallest of them
/// is the link at its quickest, and how far each one lands behind that is how late it was.
/// That lateness is the stutter you feel: a smooth stream of movements that arrives in
/// clumps draws a pointer that stalls and jumps.
///
/// A plain value type with no clock of its own, so it can be tested with made-up times.
public struct ArrivalJitter: Sendable {
    /// Enough for a long stretch of movement; older samples make way for newer ones.
    public static let capacity = 4096

    /// Arrived minus sent, in nanoseconds, oldest first once the buffer wraps.
    private var offsets: [Int64] = []
    private var next = 0

    public init() {}

    public var count: Int { offsets.count }

    public mutating func reset() {
        offsets.removeAll(keepingCapacity: true)
        next = 0
    }

    public mutating func record(sentAt: UInt64, arrivedAt: UInt64) {
        let offset = Int64(bitPattern: arrivedAt &- sentAt)
        if offsets.count < Self.capacity {
            offsets.append(offset)
        } else {
            offsets[next] = offset
            next = (next + 1) % Self.capacity
        }
    }

    /// Each sample's lateness, in milliseconds, behind the quickest one, sorted.
    ///
    /// Measured against the quickest sample of the whole window rather than the quickest so
    /// far, so the first few samples are not judged against a baseline that was not yet known.
    private var sortedLateness: [Double] {
        guard let quickest = offsets.min() else { return [] }
        return offsets.map { Double($0 - quickest) / 1_000_000 }.sorted()
    }

    /// The lateness that `fraction` of updates arrived within, in milliseconds.
    public func percentile(_ fraction: Double) -> Double {
        let sorted = sortedLateness
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * min(max(fraction, 0), 1)).rounded())
        return sorted[index]
    }

    public struct Summary: Sendable, Equatable {
        public var samples: Int
        public var median: Double
        public var p95: Double
        public var worst: Double

        /// Lateness bad enough to see. A 60 Hz screen draws every 17 ms, so updates that are
        /// routinely more than a couple of frames apart read as a pointer that stutters.
        public var isNoticeable: Bool { samples >= 50 && p95 >= 30 }

        public var description: String {
            String(format: "%d pointer updates: half within %.0f ms of the quickest, "
                   + "95%% within %.0f ms, the slowest %.0f ms late",
                   samples, median, p95, worst)
        }
    }

    public var summary: Summary {
        let sorted = sortedLateness
        guard !sorted.isEmpty else { return Summary(samples: 0, median: 0, p95: 0, worst: 0) }
        func at(_ f: Double) -> Double { sorted[Int((Double(sorted.count - 1) * f).rounded())] }
        return Summary(samples: sorted.count, median: at(0.5), p95: at(0.95), worst: sorted.last!)
    }
}
