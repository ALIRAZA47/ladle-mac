import Foundation

/// `Content-Range: bytes 0-99/1234` (total may be `*`), or `bytes */1234` on a 416.
public struct ContentRange: Equatable, Sendable {
    public var start: Int64?
    public var end: Int64?
    public var total: Int64?

    public static func parse(_ header: String) -> ContentRange? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        let spec = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let halves = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let total: Int64? = halves[1] == "*" ? nil : Int64(halves[1].trimmingCharacters(in: .whitespaces))
        if halves[1] != "*" && total == nil { return nil }
        if halves[0] == "*" { return ContentRange(start: nil, end: nil, total: total) }
        let bounds = halves[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), end >= start else { return nil }
        return ContentRange(start: start, end: end, total: total)
    }
}

public enum RetryAfter {
    /// Seconds to wait from `Retry-After` (delta-seconds or an HTTP date), capped at an hour.
    public static func seconds(from header: String?, now: Date = Date()) -> Double? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Double(raw), seconds >= 0 { return min(seconds, 3600) }
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return min(max(0, date.timeIntervalSince(now)), 3600)
            }
        }
        return nil
    }
}

public enum RedirectPolicy {
    /// Cookies and referrer from the browser go only to the download's own host (exact match).
    public static func isSameHost(_ a: URL, _ b: URL) -> Bool {
        guard let ha = a.host?.lowercased(), let hb = b.host?.lowercased() else { return false }
        return ha == hb
    }
}
