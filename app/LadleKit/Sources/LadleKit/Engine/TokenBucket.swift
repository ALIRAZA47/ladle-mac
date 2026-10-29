import Foundation

/// The one global speed limit, shared by every connection of every download.
/// Readers take tokens for the bytes they got; when the bucket runs dry they wait, which
/// stops them reading, which (through the transport) slows the servers down.
public final class TokenBucket: @unchecked Sendable {
    private struct State {
        var rate: Double?
        var tokens: Double
        var last: Double
    }

    private let state: Locked<State>
    private let clock: LadleClock

    /// - Parameter bytesPerSecond: nil for no limit.
    public init(bytesPerSecond: Int64?, clock: LadleClock = SystemClock()) {
        self.clock = clock
        let rate = bytesPerSecond.map(Double.init)
        state = Locked(State(rate: rate, tokens: 0, last: clock.uptime()))
    }

    public var limit: Int64? {
        state.current.rate.map { Int64($0) }
    }

    public func setLimit(_ bytesPerSecond: Int64?) {
        let now = clock.uptime()
        state.withLock { s in
            s.rate = bytesPerSecond.map(Double.init)
            s.tokens = 0
            s.last = now
        }
    }

    /// Small bursts are fine; about a quarter second of traffic.
    private static func capacity(for rate: Double) -> Double {
        max(rate / 4, 64 * 1024)
    }

    /// Takes `bytes` tokens and returns how long the caller must wait before reading more.
    public func reserve(_ bytes: Int, now: Double) -> Double {
        state.withLock { s -> Double in
            guard let rate = s.rate, rate > 0 else { return 0 }
            let elapsed = max(0, now - s.last)
            s.last = now
            s.tokens = min(TokenBucket.capacity(for: rate), s.tokens + elapsed * rate)
            s.tokens -= Double(bytes)
            return s.tokens >= 0 ? 0 : -s.tokens / rate
        }
    }

    /// Waits until `bytes` may be consumed under the limit.
    public func consume(_ bytes: Int) async throws {
        let wait = reserve(bytes, now: clock.uptime())
        if wait > 0 { try await clock.sleep(seconds: wait) }
    }
}
