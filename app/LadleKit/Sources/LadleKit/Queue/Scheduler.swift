import Foundation

/// Reasons downloads wait. Sleep and a lost network hold everything that wasn't started by hand;
/// battery power and Low Data networks hold only the Tonight queue.
public enum Hold: String, Codable, Hashable, Sendable {
    case battery
    case lowData
    case offline
    case sleeping

    public var holdsTonightOnly: Bool { self == .battery || self == .lowData }
}

/// Why a queued download isn't running yet.
public enum WaitReason: Equatable, Sendable {
    case nextInLine
    case tonight(startMinute: Int)
    case hold(Hold)
}

public struct SchedulePlan: Equatable, Sendable {
    public var start: [UUID] = []
    public var stop: [UUID] = []

    public init(start: [UUID] = [], stop: [UUID] = []) {
        self.start = start
        self.stop = stop
    }
}

/// Decides what runs: the Main queue up to "Downloads at the same time", the Tonight queue only
/// inside its window, and nothing a hold applies to. Downloads started by hand always run.
public enum Scheduler {
    /// The hold that keeps this download from running, if any.
    public static func blockingHold(for item: DownloadItem, holds: Set<Hold>) -> Hold? {
        guard !item.manualStart else { return nil }
        for hold in [Hold.sleeping, .offline, .battery, .lowData] where holds.contains(hold) {
            if hold.holdsTonightOnly && item.queue != .tonight { continue }
            return hold
        }
        return nil
    }

    public static func plan(items: [DownloadItem], settings: Settings, holds: Set<Hold>, now: Date, calendar: Calendar = .current) -> SchedulePlan {
        let tonightOpen = TonightWindow(settings: settings).isActive(at: now, calendar: calendar)
        var plan = SchedulePlan()
        var running = 0
        for item in items where item.status == .downloading {
            if item.manualStart {
                running += 1
            } else if blockingHold(for: item, holds: holds) != nil || (item.queue == .tonight && !tonightOpen) {
                plan.stop.append(item.id)
            } else {
                running += 1
            }
        }
        var slots = max(0, settings.maxConcurrentDownloads - running)
        for item in items where item.status == .queued {
            if item.manualStart {
                plan.start.append(item.id)
                continue
            }
            guard slots > 0, blockingHold(for: item, holds: holds) == nil else { continue }
            if item.queue == .main || tonightOpen {
                plan.start.append(item.id)
                slots -= 1
            }
        }
        // Keep running downloads over the limit if the limit was just lowered: stop the newest ones.
        let overflow = running - settings.maxConcurrentDownloads
        if overflow > 0 {
            let automatic = items.filter { $0.status == .downloading && !$0.manualStart && !plan.stop.contains($0.id) }
            plan.stop.append(contentsOf: automatic.suffix(overflow).map(\.id))
        }
        return plan
    }

    public static func waitReason(for item: DownloadItem, settings: Settings, holds: Set<Hold>, now: Date, calendar: Calendar = .current) -> WaitReason? {
        guard item.status == .queued else { return nil }
        let hold = blockingHold(for: item, holds: holds)
        if let hold, !hold.holdsTonightOnly { return .hold(hold) }
        // Outside its window, a Tonight download is waiting for tonight whatever the power source.
        if item.queue == .tonight && !item.manualStart && !TonightWindow(settings: settings).isActive(at: now, calendar: calendar) {
            return .tonight(startMinute: settings.tonightStartMinute)
        }
        if let hold { return .hold(hold) }
        return .nextInLine
    }
}
