import Foundation

/// Bytes per second over a short sliding window.
public final class SpeedMeter: @unchecked Sendable {
    private struct Sample {
        var time: Double
        var bytes: Int64
    }

    private let window: Double
    private let samples = Locked<[Sample]>([])

    public init(window: Double = 3) {
        self.window = window
    }

    public func record(_ bytes: Int, at time: Double) {
        samples.withLock { list in
            if let last = list.last, time - last.time < 0.1 {
                list[list.count - 1].bytes += Int64(bytes)
            } else {
                list.append(Sample(time: time, bytes: Int64(bytes)))
            }
            let cutoff = time - window
            if let first = list.first, first.time < cutoff {
                list.removeAll(where: { $0.time < cutoff })
            }
        }
    }

    public func rate(at time: Double) -> Double {
        samples.withLock { list -> Double in
            let cutoff = time - window
            list.removeAll(where: { $0.time < cutoff })
            guard let first = list.first else { return 0 }
            let total = list.reduce(Int64(0)) { $0 + $1.bytes }
            // Until the window fills, divide by the time actually observed (at least one second).
            let span = max(1, min(window, time - first.time + 0.1))
            return Double(total) / span
        }
    }

    public func reset() {
        samples.withLock { $0.removeAll() }
    }
}
