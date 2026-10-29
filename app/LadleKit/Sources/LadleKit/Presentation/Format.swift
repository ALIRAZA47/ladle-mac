import Foundation

/// Numbers and times as Ladle writes them: decimal units, like Finder.
public enum Format {
    private enum Unit: String {
        case kb = "KB", mb = "MB", gb = "GB"
    }

    private static func unit(_ bytes: Double) -> Unit {
        if bytes >= 999.5e6 { return .gb }
        if bytes >= 999.5e3 { return .mb }
        return .kb
    }

    private static func number(_ bytes: Double, _ unit: Unit) -> String {
        switch unit {
        case .gb:
            let value = bytes / 1e9
            return value >= 100 ? String(format: "%.0f", value) : String(format: "%.2f", value)
        case .mb:
            let value = bytes / 1e6
            return value >= 99.95 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        case .kb:
            return String(Int(max(0, (bytes / 1e3).rounded())))
        }
    }

    /// "5.79 GB", "312 MB", "18.2 MB", "640 KB".
    public static func size(_ bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        let u = unit(b)
        return "\(number(b, u)) \(u.rawValue)"
    }

    /// "3.58 of 5.79 GB", or "312 MB of 1.24 GB" when the units differ.
    public static func pair(_ done: Int64, of total: Int64) -> String {
        let a = Double(max(0, done))
        let b = Double(max(0, total))
        let ua = unit(a)
        let ub = unit(b)
        if ua == ub { return "\(number(a, ua)) of \(number(b, ub)) \(ub.rawValue)" }
        return "\(size(done)) of \(size(total))"
    }

    /// "18.4 MB/s", "640 KB/s".
    public static func speed(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        if v >= 999.5e3 { return String(format: "%.1f MB/s", v / 1e6) }
        return "\(Int((v / 1e3).rounded())) KB/s"
    }

    /// Time left: "40 s", "3 min", "1 h 12 min", or "—" when unknown.
    public static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 { return "\(Int(seconds.rounded(.up))) s" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded(.up))) min" }
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600) / 60).rounded())
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    /// How long something took: "7 seconds", "4 min", "1 h 5 min".
    public static func duration(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 1.5 { return "1 second" }
        if s < 60 { return "\(Int(s.rounded())) seconds" }
        if s < 3600 { return "\(Int((s / 60).rounded())) min" }
        let hours = Int(s / 3600)
        let minutes = Int((s.truncatingRemainder(dividingBy: 3600) / 60).rounded())
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    /// "once", "2 times".
    public static func times(_ count: Int) -> String {
        count == 1 ? "once" : "\(count) times"
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded(.down)))%"
    }

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        return formatter
    }

    /// "9:02 AM"
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("h:mm a", calendar).string(from: date)
    }

    /// "Today, 9:02 AM", "Yesterday, 11:48 PM", "Oct 27, 9:02 AM".
    public static func added(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(clock(date, calendar: calendar))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(clock(date, calendar: calendar))"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatter(sameYear ? "MMM d, h:mm a" : "MMM d, yyyy", calendar).string(from: date)
    }

    /// "8:12 AM" today, "yesterday", "Oct 27" otherwise.
    public static func finished(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return clock(date, calendar: calendar) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        return formatter("MMM d", calendar).string(from: date)
    }
}
