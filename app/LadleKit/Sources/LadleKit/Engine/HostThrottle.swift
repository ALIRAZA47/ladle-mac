import Foundation

/// Per-host connection limits. A 429 or 503 halves the connections Ladle uses for that host and
/// holds new requests until `Retry-After` has passed. The limit lifts after ten quiet minutes.
public final class HostThrottle: @unchecked Sendable {
    struct Entry {
        var cap: Int
        var notBefore: Double
        var lastPushback: Double
    }

    private let state = Locked<[String: Entry]>([:])
    private let clock: LadleClock
    public static let quietPeriod: Double = 600

    public init(clock: LadleClock = SystemClock()) {
        self.clock = clock
    }

    /// How many connections the host allows right now, given what Ladle would like to use.
    public func allowedConnections(host: String, wanted: Int) -> Int {
        let now = clock.uptime()
        return state.withLock { (map: inout [String: Entry]) -> Int in
            guard let entry = map[host.lowercased()] else { return wanted }
            if now - entry.lastPushback > HostThrottle.quietPeriod {
                map[host.lowercased()] = nil
                return wanted
            }
            return max(1, min(wanted, entry.cap))
        }
    }

    /// Seconds until requests to the host may start again (0 when they may start now).
    public func waitTime(host: String) -> Double {
        let now = clock.uptime()
        return state.withLock { (map: inout [String: Entry]) -> Double in
            guard let entry = map[host.lowercased()] else { return 0 }
            return max(0, entry.notBefore - now)
        }
    }

    /// The server pushed back: halve the connections in use and honor its `Retry-After`.
    @discardableResult
    public func pushedBack(host: String, currentConnections: Int, retryAfter: Double?) -> Int {
        let now = clock.uptime()
        return state.withLock { (map: inout [String: Entry]) -> Int in
            let key = host.lowercased()
            var entry = map[key] ?? Entry(cap: max(1, currentConnections), notBefore: 0, lastPushback: now)
            entry.cap = max(1, min(entry.cap, currentConnections) / 2)
            entry.lastPushback = now
            if let retryAfter { entry.notBefore = max(entry.notBefore, now + retryAfter) }
            map[key] = entry
            return entry.cap
        }
    }
}
