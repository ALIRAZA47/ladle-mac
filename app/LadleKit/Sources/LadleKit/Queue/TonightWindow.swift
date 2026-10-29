import Foundation

/// When the Tonight queue may run: from `startMinute` to `stopMinute` (minutes after midnight),
/// on the days in `days` (Calendar weekdays, 1 = Sunday). A window that crosses midnight
/// belongs to the day it starts on.
public struct TonightWindow: Equatable, Sendable {
    public var startMinute: Int
    public var stopMinute: Int
    public var days: Set<Int>

    public init(startMinute: Int, stopMinute: Int, days: Set<Int>) {
        self.startMinute = startMinute
        self.stopMinute = stopMinute
        self.days = days
    }

    public init(settings: Settings) {
        self.init(startMinute: settings.tonightStartMinute, stopMinute: settings.tonightStopMinute, days: Set(settings.tonightDays))
    }

    private func minuteOfDay(_ date: Date, _ calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func weekday(_ date: Date, _ calendar: Calendar) -> Int {
        calendar.component(.weekday, from: date)
    }

    private func previousDay(_ date: Date, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -1, to: date) ?? date.addingTimeInterval(-86_400)
    }

    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard !days.isEmpty else { return false }
        let minute = minuteOfDay(date, calendar)
        if startMinute < stopMinute {
            return minute >= startMinute && minute < stopMinute && days.contains(weekday(date, calendar))
        }
        // Crosses midnight (or runs a full day when start == stop).
        if minute >= startMinute { return days.contains(weekday(date, calendar)) }
        if minute < stopMinute { return days.contains(weekday(previousDay(date, calendar), calendar)) }
        return false
    }

    /// The next time the window opens, strictly after `date` (or nil when no day is selected).
    public func nextStart(after date: Date, calendar: Calendar = .current) -> Date? {
        guard !days.isEmpty else { return nil }
        let startOfToday = calendar.startOfDay(for: date)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  days.contains(weekday(day, calendar)),
                  let start = calendar.date(byAdding: .minute, value: startMinute, to: day) else { continue }
            if start > date { return start }
        }
        return nil
    }

    /// "1:00 AM"
    public static func timeLabel(minute: Int) -> String {
        let hour24 = (minute / 60) % 24
        let mins = minute % 60
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let suffix = hour24 < 12 ? "AM" : "PM"
        return "\(hour12):\(mins < 10 ? "0" : "")\(mins) \(suffix)"
    }

    /// "1 AM", or "1:30 AM" when the minutes matter.
    public static func shortLabel(minute: Int) -> String {
        let hour24 = (minute / 60) % 24
        let mins = minute % 60
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let suffix = hour24 < 12 ? "AM" : "PM"
        return mins == 0 ? "\(hour12) \(suffix)" : "\(hour12):\(mins < 10 ? "0" : "")\(mins) \(suffix)"
    }

    /// "1:00 – 7:00 AM", or "11:00 PM – 7:00 AM" across the halves of the day.
    public var rangeLabel: String {
        let start = TonightWindow.timeLabel(minute: startMinute)
        let stop = TonightWindow.timeLabel(minute: stopMinute)
        if start.suffix(2) == stop.suffix(2) {
            return "\(start.dropLast(3)) – \(stop)"
        }
        return "\(start) – \(stop)"
    }
}
