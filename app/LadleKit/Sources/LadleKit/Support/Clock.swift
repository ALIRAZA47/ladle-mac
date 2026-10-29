import Foundation

/// Time source for everything that waits or timestamps, so tests can control it.
public protocol LadleClock: Sendable {
    /// Wall-clock time, used for timestamps and the Tonight window.
    func now() -> Date
    /// Monotonic seconds, used for rates and backoff.
    func uptime() -> Double
    func sleep(seconds: Double) async throws
}

public struct SystemClock: LadleClock {
    public init() {}

    public func now() -> Date { Date() }

    public func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
