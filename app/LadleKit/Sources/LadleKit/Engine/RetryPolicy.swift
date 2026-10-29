import Foundation

/// Backoff for failed pieces: 1, 2, 4, 8, 16 s (then 16 s), each with ±20 % jitter.
public struct RetryPolicy: Sendable {
    /// Retries allowed after the first try ("Retry failed downloads": 0, 1, 3, 5, 10).
    public var limit: Int
    public var base: Double = 1
    public var cap: Double = 16
    public var jitter: Double = 0.2

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// Delay before retry number `attempt` (1-based). `random` is in 0…1.
    public func delay(forAttempt attempt: Int, random: Double = Double.random(in: 0...1)) -> Double {
        let exponent = Double(max(0, attempt - 1))
        let raw = min(cap, base * pow(2, exponent))
        let factor = 1 + jitter * (2 * min(max(random, 0), 1) - 1)
        return raw * factor
    }

    /// Whether another try is allowed after `failures` failures in a row.
    public func allowsRetry(afterFailures failures: Int) -> Bool {
        failures <= limit
    }
}

/// What to do with an HTTP status on a piece request.
public enum ResponseClass: Equatable, Sendable {
    case ok
    /// 429/503: the server is asking Ladle to slow down.
    case slowDown
    /// Worth trying again (5xx, 408).
    case retry
    /// 416 while resuming: the file on the server is no longer the one we started.
    case rangeNotSatisfiable
    /// Won't get better by retrying.
    case fatal(DownloadFailure)

    public static func classify(status: Int) -> ResponseClass {
        switch status {
        case 200, 206: return .ok
        case 429, 503: return .slowDown
        case 408, 425, 500, 502, 504, 520...529: return .retry
        case 416: return .rangeNotSatisfiable
        case 401, 403, 407: return .fatal(DownloadFailure(.forbidden, httpStatus: status))
        case 404, 410: return .fatal(DownloadFailure(.notFound, httpStatus: status))
        case 500...599: return .retry
        default: return .fatal(DownloadFailure(.invalidResponse, httpStatus: status))
        }
    }
}
