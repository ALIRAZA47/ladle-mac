import Foundation

/// The sidebar's choices.
public enum LibrarySelection: Hashable, Sendable {
    case all, active, queued, completed, failed
    case category(FileCategory)
    case queue(QueueKind)

    public var title: String {
        switch self {
        case .all: return "All Downloads"
        case .active: return "Active"
        case .queued: return "Queued"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .category(let category): return category.title
        case .queue(.main): return "Main queue"
        case .queue(.tonight): return "Tonight"
        }
    }

    public var emptyTitle: String {
        switch self {
        case .all: return "No downloads yet"
        case .active: return "Nothing downloading"
        case .queued: return "Nothing queued"
        case .completed: return "Nothing finished yet"
        case .failed: return "No failed downloads"
        case .category(.video): return "No videos yet"
        case .category(.music): return "No music yet"
        case .category(.documents): return "No documents yet"
        case .category(.archives): return "No archives yet"
        case .category(.apps): return "No apps yet"
        case .category(.images): return "No images yet"
        case .category(.other): return "Nothing here yet"
        case .queue(.main): return "The main queue is empty"
        case .queue(.tonight): return "Nothing planned for tonight"
        }
    }

    public func includes(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case .active: return item.status == .downloading || item.status == .paused
        case .queued: return item.status == .queued
        case .completed: return item.status == .completed
        case .failed: return item.status == .failed
        case .category(let category): return item.category == category
        case .queue(let queue): return item.queue == queue && item.status != .completed && item.status != .failed
        }
    }

    /// Sidebar counts, as on the design: the Tonight count is only what's still waiting.
    public func count(in items: [DownloadItem]) -> Int {
        switch self {
        case .queue(.tonight): return items.filter { $0.queue == .tonight && $0.status == .queued }.count
        default: return items.filter(includes).count
        }
    }
}

public enum ChipStyle: Sendable {
    case neutral, danger
}

public struct Chip: Equatable, Sendable {
    public var text: String
    public var style: ChipStyle
}

public enum SegmentStyle: Sendable {
    case pouring, paused, waiting, finished, failed
}

/// One segment of a progress bar, or one arc of the connection ring.
public struct SegmentState: Equatable, Sendable {
    public var fraction: Double
    public var style: SegmentStyle

    /// Glows and flickers: connection is pouring and its piece isn't done.
    public var isLive: Bool { style == .pouring && fraction > 0 && fraction < 1 }
}

public enum PrimaryAction: Sendable {
    case pause, start, resume, startNow, retry, startOver, open

    public var title: String {
        switch self {
        case .pause: return "Pause"
        case .start: return "Start"
        case .resume: return "Resume"
        case .startNow: return "Start now"
        case .retry: return "Retry"
        case .startOver: return "Start over"
        case .open: return "Open"
        }
    }
}

public struct Stat: Equatable, Sendable {
    public var label: String
    public var value: String
}

public struct DetailsPresentation: Equatable, Sendable {
    public var center: String
    public var centerSub: String
    public var centerIsDanger: Bool
    public var stats: [Stat]
    public var note: String
    public var noteIsDanger: Bool
    public var primary: PrimaryAction
    public var ringLabel: String
    public var arcs: [SegmentState]
}

public enum GroupKind: String, Sendable {
    case downloading, paused, upNext, needsAttention, completedToday, completedEarlier

    public var label: String {
        switch self {
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .upNext: return "Up next"
        case .needsAttention: return "Needs attention"
        case .completedToday: return "Completed today"
        case .completedEarlier: return "Completed earlier"
        }
    }
}

public struct ItemGroup: Identifiable, Equatable, Sendable {
    public var kind: GroupKind
    public var count: Int
    public var items: [DownloadItem]
    /// Shows a Show/Hide toggle.
    public var isCollapsible: Bool
    public var isCollapsed: Bool

    public var id: GroupKind { kind }
}

/// Everything shown about one download, worked out from the item.
public enum ItemPresentation {
    public static func holdText(_ hold: Hold) -> String {
        switch hold {
        case .battery: return "Waiting until you plug in"
        case .lowData: return "Waiting for a regular network"
        case .offline: return "Waiting for the network"
        case .sleeping: return "Paused while the Mac sleeps"
        }
    }

    public static func extensionBadge(_ item: DownloadItem) -> String {
        let ext = item.fileExtension
        return ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(4))
    }

    /// How many segments the bar and ring have: one per connection, one when the size is unknown.
    public static func slotCount(_ item: DownloadItem) -> Int {
        if item.kind == .file && (item.totalBytes == nil || item.resumable == false) { return 1 }
        return max(1, item.connectionCount)
    }

    public static func fractions(_ item: DownloadItem) -> [Double] {
        let slots = slotCount(item)
        if item.kind == .hls, let count = item.hls?.segmentCount, count > 0 {
            let done = Set(item.hls?.completedSegments ?? [])
            return (0..<slots).map { k in
                let lower = count * k / slots
                let upper = count * (k + 1) / slots
                guard upper > lower else { return done.isEmpty ? 0 : 1 }
                let filled = (lower..<upper).filter(done.contains).count
                return Double(filled) / Double(upper - lower)
            }
        }
        guard let total = item.totalBytes, total > 0 else {
            return [Double](repeating: 0, count: slots)
        }
        if slots == 1 { return [min(1, Double(item.receivedBytes) / Double(total))] }
        if item.pieces.isEmpty {
            return [Double](repeating: 0, count: slots)
        }
        return PieceTable.slotFractions(pieces: item.pieces, total: total, slots: slots)
    }

    /// The bar: one segment per connection; a single steel bar once finished.
    public static func segments(_ item: DownloadItem) -> [SegmentState] {
        switch item.status {
        case .completed:
            return [SegmentState(fraction: 1, style: .finished)]
        case .failed:
            return fractions(item).map { SegmentState(fraction: $0, style: .failed) }
        case .paused:
            return fractions(item).map { SegmentState(fraction: $0, style: .paused) }
        case .queued:
            return fractions(item).map { SegmentState(fraction: $0, style: .waiting) }
        case .downloading:
            return fractions(item).map { SegmentState(fraction: $0, style: .pouring) }
        }
    }

    /// The ring: like the bar, but finished downloads keep one arc per connection.
    public static func arcs(_ item: DownloadItem) -> [SegmentState] {
        if item.status == .completed {
            return [SegmentState](repeating: SegmentState(fraction: 1, style: .finished), count: slotCount(item))
        }
        return segments(item)
    }

    public static func chip(_ item: DownloadItem, wait: WaitReason?) -> Chip? {
        switch item.status {
        case .paused:
            return Chip(text: item.neverStarted ? "Later" : "Paused", style: .neutral)
        case .queued:
            switch wait {
            case .tonight?: return Chip(text: "Tonight", style: .neutral)
            case .hold?: return Chip(text: "Waiting", style: .neutral)
            default: return item.queue == .tonight ? Chip(text: "Tonight", style: .neutral) : nil
            }
        case .failed:
            return Chip(text: "Failed", style: .danger)
        case .completed:
            switch item.checksumState {
            case .verified?: return Chip(text: "Verified", style: .neutral)
            case .mismatch?: return Chip(text: "Doesn’t match", style: .danger)
            case .verifying?: return Chip(text: "Checking…", style: .neutral)
            case nil: return nil
            }
        case .downloading:
            return nil
        }
    }

    public static func speedText(_ item: DownloadItem, live: LiveInfo?) -> String {
        guard item.status == .downloading else { return "" }
        return Format.speed(live?.speed ?? 0)
    }

    public static func timeLeft(_ item: DownloadItem, live: LiveInfo?) -> Double? {
        guard let total = item.totalBytes, let speed = live?.speed, speed > 0 else { return nil }
        return Double(max(0, total - item.receivedBytes)) / speed
    }

    private static func sizeOrProgress(_ item: DownloadItem) -> String? {
        if let total = item.totalBytes {
            return item.receivedBytes > 0 ? Format.pair(item.receivedBytes, of: total) : Format.size(total)
        }
        return item.receivedBytes > 0 ? Format.size(item.receivedBytes) : nil
    }

    /// The grey line under the bar.
    public static func meta(_ item: DownloadItem, live: LiveInfo?, wait: WaitReason?, settings: Settings, now: Date, calendar: Calendar = .current) -> String {
        switch item.status {
        case .downloading:
            if item.kind == .hls && item.totalBytes == nil, let count = item.hls?.segmentCount {
                return "\(item.hls?.completedSegments.count ?? 0) of \(count) segments"
            }
            guard let total = item.totalBytes else {
                return item.receivedBytes > 0 ? "\(Format.size(item.receivedBytes)) so far" : "Connecting…"
            }
            if let left = timeLeft(item, live: live) {
                return "\(Format.pair(item.receivedBytes, of: total)) · \(Format.eta(left)) left"
            }
            return item.receivedBytes > 0 ? Format.pair(item.receivedBytes, of: total) : "Connecting…"
        case .paused:
            if item.neverStarted {
                return item.totalBytes.map { "Not started · \(Format.size($0))" } ?? "Not started"
            }
            let progress = sizeOrProgress(item) ?? "Not started"
            if item.resumable == false && item.receivedBytes > 0 {
                return "\(progress) · this server can’t resume"
            }
            return item.receivedBytes > 0 ? "\(progress) · resumes where it stopped" : progress
        case .queued:
            let lead: String
            switch wait ?? .nextInLine {
            case .nextInLine: lead = "Next in line"
            case .tonight(let minute): lead = "Starts at \(TonightWindow.timeLabel(minute: minute))"
            case .hold(let hold): lead = holdText(hold)
            }
            if let detail = sizeOrProgress(item) { return "\(lead) · \(detail)" }
            return lead
        case .failed:
            let reason = (item.failure?.message ?? "Something went wrong").lowercasedFirst
            if let fraction = item.fractionDone {
                return "Stopped at \(Format.percent(fraction)) · \(reason)"
            }
            return "Stopped · \(reason)"
        case .completed:
            let size = item.totalBytes.map(Format.size) ?? Format.size(item.receivedBytes)
            if let finished = item.finishedAt {
                return "\(size) · finished \(Format.finished(finished, now: now, calendar: calendar))"
            }
            return size
        }
    }

    public static func metaIsDanger(_ item: DownloadItem) -> Bool {
        item.status == .failed
    }

    public static func primaryAction(_ item: DownloadItem) -> PrimaryAction {
        switch item.status {
        case .downloading: return .pause
        case .paused: return item.neverStarted ? .start : .resume
        case .queued: return .startNow
        case .failed: return item.failure?.needsStartOver == true ? .startOver : .retry
        case .completed: return .open
        }
    }

    public static func details(_ item: DownloadItem, live: LiveInfo?, wait: WaitReason?, settings: Settings, now: Date, calendar: Calendar = .current) -> DetailsPresentation {
        let slots = slotCount(item)
        let fraction = item.fractionDone
        let percent = fraction.map(Format.percent) ?? "—"
        let size = item.totalBytes.map(Format.size) ?? "Unknown"
        var center = percent
        var sub = ""
        var stats: [Stat] = []
        var note = ""
        var danger = false
        let connections = slots == 1 ? "1 connection" : "\(slots) connections"

        switch item.status {
        case .downloading:
            sub = Format.speed(live?.speed ?? 0)
            if item.totalBytes == nil { center = Format.size(item.receivedBytes) }
            stats = [
                Stat(label: "Speed", value: Format.speed(live?.speed ?? 0)),
                Stat(label: "Time left", value: timeLeft(item, live: live).map(Format.eta) ?? "—"),
                Stat(label: "Size", value: size),
            ]
            if item.kind == .file && item.totalBytes == nil {
                note = "The server didn’t say how big the file is, so Ladle uses one connection."
            } else if item.kind == .file && item.resumable == false {
                note = "This server sends the file in one piece, over one connection."
            } else {
                let pouring = min(slots, live?.activeConnections ?? 0)
                note = "Each arc is one connection · \(pouring) of \(slots) pouring"
            }
        case .paused:
            sub = "Paused"
            if item.totalBytes == nil { center = Format.size(item.receivedBytes) }
            stats = [
                Stat(label: "Downloaded", value: Format.size(item.receivedBytes)),
                Stat(label: "Left", value: item.totalBytes.map { Format.size(max(0, $0 - item.receivedBytes)) } ?? "—"),
                Stat(label: "Size", value: size),
            ]
            if item.neverStarted {
                center = "Later"
                sub = "Not started"
                note = "Added to your list without starting. Start it whenever you’re ready."
            } else if item.resumable == false && item.receivedBytes > 0 {
                note = "This server can’t resume, so the file has to start over."
            } else if slots == 1 {
                note = "The connection is paused. Resume picks up exactly where it stopped."
            } else {
                note = "\(connections) paused. Resume picks up exactly where each one stopped."
            }
        case .queued:
            let window = TonightWindow(settings: settings)
            switch wait ?? .nextInLine {
            case .tonight(let minute):
                center = TonightWindow.shortLabel(minute: minute)
                sub = "Tonight"
                stats = [
                    Stat(label: "Starts", value: TonightWindow.timeLabel(minute: minute)),
                    Stat(label: "Connections", value: String(slots)),
                    Stat(label: "Size", value: size),
                ]
                let range = "\(TonightWindow.timeLabel(minute: window.startMinute).dropLast(3)) to \(TonightWindow.timeLabel(minute: window.stopMinute))"
                note = "Waits for the Tonight queue, \(range)."
                if settings.whenTonightFinishes == .sleep { note += " Ladle can put your Mac to sleep when it’s done." }
            case .hold(let hold):
                center = item.receivedBytes > 0 ? percent : "Wait"
                sub = "Waiting"
                stats = [
                    Stat(label: "Downloaded", value: Format.size(item.receivedBytes)),
                    Stat(label: "Connections", value: String(slots)),
                    Stat(label: "Size", value: size),
                ]
                switch hold {
                case .battery: note = "On battery power the Tonight queue waits. It carries on by itself once you plug in."
                case .lowData: note = "This network is in Low Data Mode, so the Tonight queue waits. It carries on by itself on a regular network."
                case .offline: note = "Downloads pick up when your Mac is back online."
                case .sleeping: note = "Downloads pick up when your Mac wakes."
                }
            case .nextInLine:
                center = "Next"
                sub = "In line"
                stats = [
                    Stat(label: "Starts", value: "Soon"),
                    Stat(label: "Connections", value: String(slots)),
                    Stat(label: "Size", value: size),
                ]
                let n = settings.maxConcurrentDownloads
                note = "Starts as soon as a slot frees up. Ladle runs \(n) download\(n == 1 ? "" : "s") at a time."
            }
        case .completed:
            center = "Done"
            sub = "Ready to open"
            let checksum: String
            switch item.checksumState {
            case .verified?: checksum = "Verified"
            case .mismatch?: checksum = "Doesn’t match"
            case .verifying?: checksum = "Checking…"
            case nil: checksum = "—"
            }
            stats = [
                Stat(label: "Finished", value: item.finishedAt.map { Format.clock($0, calendar: calendar) } ?? "—"),
                Stat(label: "Size", value: item.totalBytes.map(Format.size) ?? Format.size(item.receivedBytes)),
                Stat(label: "Checksum", value: checksum),
            ]
            let algorithm = item.checksum?.algorithm.title ?? "checksum"
            let whose = item.checksum?.source == .pasted ? "you pasted" : "the site published"
            switch item.checksumState {
            case .verified?:
                note = "Matches the \(algorithm) \(whose)."
            case .mismatch?:
                note = "Doesn’t match the \(algorithm) \(whose). The file may be damaged or changed."
                danger = true
            case .verifying?:
                note = "Checking the \(algorithm) \(whose)…"
            case nil:
                if item.kind == .hls {
                    note = "All \(item.hls?.segmentCount ?? 0) segments joined into one file."
                } else if slots == 1 {
                    note = "Saved over one connection."
                } else {
                    note = "All \(slots) pieces joined into one file."
                }
            }
        case .failed:
            sub = "Stopped"
            danger = true
            stats = [
                Stat(label: "Stopped at", value: percent),
                Stat(label: "Tried", value: Format.times(max(1, item.attempts))),
                Stat(label: "Size", value: size),
            ]
            let message = item.failure?.message ?? "Something went wrong"
            if item.failure?.needsStartOver == true {
                note = "\(message). Start over to download it again from the beginning."
            } else if item.receivedBytes > 0 {
                note = "\(message). Your progress is saved, so Retry picks up where it stopped."
            } else {
                note = "\(message). Retry tries again."
            }
        }
        return DetailsPresentation(
            center: center,
            centerSub: sub,
            centerIsDanger: item.status == .failed,
            stats: stats,
            note: note,
            noteIsDanger: danger,
            primary: primaryAction(item),
            ringLabel: "\(connections), \(percent) downloaded",
            arcs: arcs(item)
        )
    }
}

/// The list in the main window: groups, title and subtitle.
public enum ListPresentation {
    public static func filter(_ items: [DownloadItem], selection: LibrarySelection, search: String) -> [DownloadItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            selection.includes(item) && (query.isEmpty || item.fileName.lowercased().contains(query) || item.host.lowercased().contains(query))
        }
    }

    public static func groups(_ items: [DownloadItem], selection: LibrarySelection, search: String, showCompleted: Bool, now: Date, calendar: Calendar = .current) -> [ItemGroup] {
        let visible = filter(items, selection: selection, search: search)
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        let collapse = !showCompleted && selection != .completed && !searching
        let toggle = selection != .completed && !searching
        func byAddedDesc(_ a: DownloadItem, _ b: DownloadItem) -> Bool { a.addedAt > b.addedAt }
        let completed = visible.filter { $0.status == .completed }.sorted { ($0.finishedAt ?? $0.addedAt) > ($1.finishedAt ?? $1.addedAt) }
        let today = completed.filter { calendar.isDate($0.finishedAt ?? $0.addedAt, inSameDayAs: now) }
        let earlier = completed.filter { !calendar.isDate($0.finishedAt ?? $0.addedAt, inSameDayAs: now) }
        let upNext = visible.filter { $0.status == .queued }.sorted { a, b in
            if a.manualStart != b.manualStart { return a.manualStart }
            if a.queue != b.queue { return a.queue == .main }
            return a.addedAt < b.addedAt
        }
        let lists: [(GroupKind, [DownloadItem], Bool)] = [
            (.downloading, visible.filter { $0.status == .downloading }.sorted(by: byAddedDesc), false),
            (.paused, visible.filter { $0.status == .paused }.sorted(by: byAddedDesc), false),
            (.upNext, upNext, false),
            (.needsAttention, visible.filter { $0.status == .failed }.sorted(by: byAddedDesc), false),
            (.completedToday, today, true),
            (.completedEarlier, earlier, true),
        ]
        return lists.compactMap { kind, list, collapsible in
            guard !list.isEmpty else { return nil }
            let collapsed = collapsible && collapse
            return ItemGroup(kind: kind, count: list.count, items: collapsed ? [] : list, isCollapsible: collapsible && toggle, isCollapsed: collapsed)
        }
    }

    public static func title(selection: LibrarySelection, search: String) -> String {
        search.trimmingCharacters(in: .whitespaces).isEmpty ? selection.title : "Search"
    }

    public static func emptyTitle(selection: LibrarySelection, search: String) -> String {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? selection.emptyTitle : "Nothing matches “\(query)”"
    }

    public static func subtitle(selection: LibrarySelection, search: String, snapshot: CoordinatorSnapshot) -> String {
        let query = search.trimmingCharacters(in: .whitespaces)
        let visible = filter(snapshot.items, selection: selection, search: search)
        if !query.isEmpty { return visible.count == 1 ? "1 match" : "\(visible.count) matches" }
        let settings = snapshot.settings
        switch selection {
        case .queue(.tonight):
            let range = TonightWindow(settings: settings).rangeLabel
            return settings.whenTonightFinishes == .sleep ? "Runs \(range), then lets your Mac sleep" : "Runs \(range)"
        case .queue(.main):
            let n = settings.maxConcurrentDownloads
            return "Runs \(n) download\(n == 1 ? "" : "s") at a time, the rest wait their turn"
        case .all, .active:
            let downloading = snapshot.items.filter { $0.status == .downloading }.count
            if downloading > 0 { return "\(downloading) downloading · \(Format.speed(snapshot.totalSpeed))" }
            for item in snapshot.items where item.status == .queued {
                if case .hold(let hold)? = Scheduler.waitReason(for: item, settings: settings, holds: snapshot.holds, now: snapshot.date) {
                    return ItemPresentation.holdText(hold)
                }
            }
            return "Nothing downloading right now"
        default:
            return visible.count == 1 ? "1 item" : "\(visible.count) items"
        }
    }

    /// Whether the header's pause button pauses (something is running or waiting) or resumes.
    public static func pauseAllPauses(_ items: [DownloadItem]) -> Bool {
        items.contains { $0.status == .downloading || ($0.status == .queued && $0.queue == .main) }
    }
}

extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
