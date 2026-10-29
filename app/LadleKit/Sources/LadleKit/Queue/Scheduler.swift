import Foundation

/// Reasons every download waits, whatever its queue.
public enum Hold: String, Codable, Hashable, Sendable {
    case battery
    case lowData
    case offline
    case sleeping
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
/// inside its window, nothing while a hold applies — except downloads started by hand.
public enum Scheduler {
    public static func plan(items: [DownloadItem], settings: Settings, holds: Set<Hold>, now: Date, calendar: Calendar = .current) -> SchedulePlan {
        let tonightOpen = TonightWindow(settings: settings).isActive(at: now, calendar: calendar)
        var plan = SchedulePlan()
        var running = 0
        for item in items where item.status == .downloading {
            if item.manualStart {
                running += 1
            } else if !holds.isEmpty || (item.queue == .tonight && !tonightOpen) {
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
            guard holds.isEmpty, slots > 0 else { continue }
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
        for hold in [Hold.sleeping, .offline, .battery, .lowData] where holds.contains(hold) {
            return .hold(hold)
        }
        if item.queue == .tonight && !TonightWindow(settings: settings).isActive(at: now, calendar: calendar) {
            return .tonight(startMinute: settings.tonightStartMinute)
        }
        return .nextInLine
    }
}
