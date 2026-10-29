import XCTest
@testable import LadleKit

final class FormatTests: XCTestCase {
    func testSizesMatchTheDesign() {
        XCTAssertEqual(Format.size(5_790_000_000), "5.79 GB")
        XCTAssertEqual(Format.size(312_000_000), "312 MB")
        XCTAssertEqual(Format.size(18_200_000), "18.2 MB")
        XCTAssertEqual(Format.size(94_300_000), "94.3 MB")
        XCTAssertEqual(Format.size(12_400_000_000), "12.40 GB")
        XCTAssertEqual(Format.size(120_000_000_000), "120 GB")
        XCTAssertEqual(Format.size(640_000), "640 KB")
        XCTAssertEqual(Format.size(0), "0 KB")
        XCTAssertEqual(Format.size(999_600_000), "1.00 GB", "no “1000 MB”")
        XCTAssertEqual(Format.size(999_600), "1.0 MB")
    }

    func testPairs() {
        XCTAssertEqual(Format.pair(3_580_000_000, of: 5_790_000_000), "3.58 of 5.79 GB")
        XCTAssertEqual(Format.pair(312_000_000, of: 1_240_000_000), "312 MB of 1.24 GB")
        XCTAssertEqual(Format.pair(60_000_000, of: 846_000_000), "60.0 of 846 MB")
    }

    func testSpeedsAndTimes() {
        XCTAssertEqual(Format.speed(18_400_000), "18.4 MB/s")
        XCTAssertEqual(Format.speed(640_400), "640 KB/s")
        XCTAssertEqual(Format.speed(0), "0 KB/s")
        XCTAssertEqual(Format.eta(40.2), "41 s")
        XCTAssertEqual(Format.eta(150), "3 min")
        XCTAssertEqual(Format.eta(4320), "1 h 12 min")
        XCTAssertEqual(Format.eta(7200), "2 h")
        XCTAssertEqual(Format.eta(.infinity), "—")
        XCTAssertEqual(Format.duration(7), "7 seconds")
        XCTAssertEqual(Format.duration(1), "1 second")
        XCTAssertEqual(Format.duration(240), "4 min")
        XCTAssertEqual(Format.times(1), "once")
        XCTAssertEqual(Format.times(4), "4 times")
        XCTAssertEqual(Format.percent(0.629), "62%")
    }

    func testDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9, minute: 30))!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9, minute: 2))!
        let lastNight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 23, minute: 48))!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 14, minute: 5))!
        XCTAssertEqual(Format.clock(morning, calendar: calendar), "9:02 AM")
        XCTAssertEqual(Format.added(morning, now: now, calendar: calendar), "Today, 9:02 AM")
        XCTAssertEqual(Format.added(lastNight, now: now, calendar: calendar), "Yesterday, 11:48 PM")
        XCTAssertEqual(Format.added(earlier, now: now, calendar: calendar), "Oct 27, 2:05 PM")
        XCTAssertEqual(Format.finished(morning, now: now, calendar: calendar), "9:02 AM")
        XCTAssertEqual(Format.finished(lastNight, now: now, calendar: calendar), "yesterday")
    }
}

final class PresentationTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9, minute: 30))!

    func make(_ name: String, status: DownloadStatus, total: Int64? = 5_790_000_000, received: Int64 = 0, queue: QueueKind = .main) -> DownloadItem {
        var item = DownloadItem(url: URL(string: "https://releases.ubuntu.com/24.04/\(name)")!, fileName: name, directory: "/tmp", queue: queue, addedAt: now.addingTimeInterval(-600))
        item.status = status
        item.totalBytes = total
        item.receivedBytes = received
        item.connectionCount = 8
        item.resumable = true
        if let total {
            let pieces = PieceTable.initialPieces(total: total, connections: 8)
            let share = received / Int64(pieces.count)
            item.pieces = pieces.map { Piece(start: $0.start, end: $0.end, received: min($0.length, share)) }
        }
        return item
    }

    func testDownloadingRow() {
        let item = make("ubuntu-24.04.2-desktop-amd64.iso", status: .downloading, received: 3_580_000_000)
        let live = LiveInfo(speed: 18_400_000, activeConnections: 8)
        XCTAssertEqual(ItemPresentation.meta(item, live: live, wait: nil, settings: Settings(), now: now), "3.58 of 5.79 GB · 3 min left")
        XCTAssertEqual(ItemPresentation.speedText(item, live: live), "18.4 MB/s")
        XCTAssertNil(ItemPresentation.chip(item, wait: nil))
        let segments = ItemPresentation.segments(item)
        XCTAssertEqual(segments.count, 8)
        XCTAssertTrue(segments.allSatisfy { $0.style == .pouring })
        XCTAssertTrue(segments[0].isLive)
        XCTAssertEqual(ItemPresentation.extensionBadge(item), "ISO")
        let details = ItemPresentation.details(item, live: live, wait: nil, settings: Settings(), now: now, calendar: calendar)
        XCTAssertEqual(details.center, "61%")
        XCTAssertEqual(details.centerSub, "18.4 MB/s")
        XCTAssertEqual(details.stats.map(\.label), ["Speed", "Time left", "Size"])
        XCTAssertEqual(details.stats.map(\.value), ["18.4 MB/s", "3 min", "5.79 GB"])
        XCTAssertEqual(details.note, "Each arc is one connection · 8 of 8 pouring")
        XCTAssertEqual(details.primary, .pause)
        XCTAssertEqual(details.ringLabel, "8 connections, 61% downloaded")
        XCTAssertEqual(details.arcs.count, 8)
    }

    func testPausedRow() {
        let item = make("brand-assets-2026.zip", status: .paused, total: 846_000_000, received: 460_000_000)
        XCTAssertEqual(ItemPresentation.meta(item, live: nil, wait: nil, settings: Settings(), now: now), "460 of 846 MB · resumes where it stopped")
        XCTAssertEqual(ItemPresentation.chip(item, wait: nil), Chip(text: "Paused", style: .neutral))
        XCTAssertTrue(ItemPresentation.segments(item).allSatisfy { $0.style == .paused })
        let details = ItemPresentation.details(item, live: nil, wait: nil, settings: Settings(), now: now)
        XCTAssertEqual(details.centerSub, "Paused")
        XCTAssertEqual(details.note, "8 connections paused. Resume picks up exactly where each one stopped.")
        XCTAssertEqual(details.primary, .resume)
        var single = item
        single.resumable = false
        XCTAssertEqual(ItemPresentation.meta(single, live: nil, wait: nil, settings: Settings(), now: now), "460 of 846 MB · this server can’t resume")
    }

    func testQueuedRows() {
        let next = make("the-long-take-ep-142.mp3", status: .queued, total: 94_300_000)
        XCTAssertEqual(ItemPresentation.meta(next, live: nil, wait: .nextInLine, settings: Settings(), now: now), "Next in line · 94.3 MB")
        let nextDetails = ItemPresentation.details(next, live: nil, wait: .nextInLine, settings: Settings(), now: now)
        XCTAssertEqual(nextDetails.center, "Next")
        XCTAssertEqual(nextDetails.note, "Starts as soon as a slot frees up. Ladle runs 3 downloads at a time.")
        XCTAssertEqual(nextDetails.primary, .startNow)

        let tonight = make("wallpapers-4k-pack.zip", status: .queued, total: 2_100_000_000, queue: .tonight)
        XCTAssertEqual(ItemPresentation.meta(tonight, live: nil, wait: .tonight(startMinute: 60), settings: Settings(), now: now), "Starts at 1:00 AM · 2.10 GB")
        XCTAssertEqual(ItemPresentation.chip(tonight, wait: .tonight(startMinute: 60))?.text, "Tonight")
        let details = ItemPresentation.details(tonight, live: nil, wait: .tonight(startMinute: 60), settings: Settings(), now: now)
        XCTAssertEqual(details.center, "1 AM")
        XCTAssertEqual(details.centerSub, "Tonight")
        XCTAssertEqual(details.stats.map(\.value), ["1:00 AM", "8", "2.10 GB"])
        XCTAssertEqual(details.note, "Waits for the Tonight queue, 1:00 to 7:00 AM. Ladle can put your Mac to sleep when it’s done.")

        let held = make("x.zip", status: .queued, total: 1_000_000_000, received: 500_000_000)
        XCTAssertEqual(ItemPresentation.meta(held, live: nil, wait: .hold(.battery), settings: Settings(), now: now), "Paused on battery power · 500 MB of 1.00 GB")
    }

    func testFailedRow() {
        var item = make("imagenet-subset-train.tar.gz", status: .failed, total: 12_400_000_000, received: 3_720_000_000)
        item.failure = DownloadFailure(.timedOut)
        item.attempts = 4
        XCTAssertEqual(ItemPresentation.meta(item, live: nil, wait: nil, settings: Settings(), now: now), "Stopped at 30% · the server stopped responding")
        XCTAssertEqual(ItemPresentation.chip(item, wait: nil), Chip(text: "Failed", style: .danger))
        XCTAssertTrue(ItemPresentation.metaIsDanger(item))
        let details = ItemPresentation.details(item, live: nil, wait: nil, settings: Settings(), now: now)
        XCTAssertEqual(details.centerSub, "Stopped")
        XCTAssertEqual(details.stats.map(\.value), ["30%", "4 times", "12.40 GB"])
        XCTAssertEqual(details.note, "The server stopped responding. Your progress is saved, so Retry picks up where it stopped.")
        XCTAssertEqual(details.primary, .retry)
        item.failure = DownloadFailure(.changedOnServer)
        XCTAssertEqual(ItemPresentation.primaryAction(item), .startOver)
    }

    func testCompletedRow() {
        var item = make("node-v22.11.0.pkg", status: .completed, total: 78_100_000, received: 78_100_000)
        item.finishedAt = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 8, minute: 31))
        item.checksumState = .verified
        item.checksum = ExpectedChecksum(algorithm: .sha256, value: String(repeating: "a", count: 64), source: .sidecar)
        XCTAssertEqual(ItemPresentation.meta(item, live: nil, wait: nil, settings: Settings(), now: now, calendar: calendar), "78.1 MB · finished 8:31 AM")
        XCTAssertEqual(ItemPresentation.chip(item, wait: nil)?.text, "Verified")
        XCTAssertEqual(ItemPresentation.segments(item), [SegmentState(fraction: 1, style: .finished)], "one steel bar")
        let details = ItemPresentation.details(item, live: nil, wait: nil, settings: Settings(), now: now, calendar: calendar)
        XCTAssertEqual(details.center, "Done")
        XCTAssertEqual(details.stats.map(\.value), ["8:31 AM", "78.1 MB", "Verified"])
        XCTAssertEqual(details.note, "Matches the SHA-256 the site published.")
        XCTAssertEqual(details.primary, .open)
        XCTAssertEqual(details.arcs.count, 8)
        item.checksumState = .mismatch
        XCTAssertEqual(ItemPresentation.chip(item, wait: nil)?.style, .danger)
        XCTAssertTrue(ItemPresentation.details(item, live: nil, wait: nil, settings: Settings(), now: now).noteIsDanger)
        item.checksumState = nil
        XCTAssertEqual(ItemPresentation.details(item, live: nil, wait: nil, settings: Settings(), now: now).note, "All 8 pieces joined into one file.")
    }

    func testUnknownSizeUsesOneSegment() {
        var item = make("stream.bin", status: .downloading, total: nil, received: 3_000_000)
        item.resumable = false
        XCTAssertEqual(ItemPresentation.segments(item).count, 1)
        XCTAssertEqual(ItemPresentation.meta(item, live: LiveInfo(speed: 1_000_000), wait: nil, settings: Settings(), now: now), "3.0 MB so far")
    }

    func testGroupsAndCollapsedCompleted() {
        var done = make("a.pdf", status: .completed, total: 1, received: 1)
        done.finishedAt = now.addingTimeInterval(-60)
        var old = make("b.pdf", status: .completed, total: 1, received: 1)
        old.finishedAt = now.addingTimeInterval(-3 * 86_400)
        let items = [
            make("d1.iso", status: .downloading), make("p1.zip", status: .paused),
            make("q1.mp3", status: .queued), make("f1.gz", status: .failed), done, old,
        ]
        let groups = ListPresentation.groups(items, selection: .all, search: "", showCompleted: false, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.kind.label), ["Downloading", "Paused", "Up next", "Needs attention", "Completed today", "Completed earlier"])
        XCTAssertTrue(groups[4].isCollapsed)
        XCTAssertTrue(groups[4].items.isEmpty)
        XCTAssertEqual(groups[4].count, 1)
        XCTAssertTrue(groups[4].isCollapsible)
        let shown = ListPresentation.groups(items, selection: .all, search: "", showCompleted: true, now: now, calendar: calendar)
        XCTAssertEqual(shown[4].items.count, 1)
        let completedView = ListPresentation.groups(items, selection: .completed, search: "", showCompleted: false, now: now, calendar: calendar)
        XCTAssertFalse(completedView[0].isCollapsed)
        XCTAssertFalse(completedView[0].isCollapsible)
        let search = ListPresentation.groups(items, selection: .all, search: "PDF", showCompleted: false, now: now, calendar: calendar)
        XCTAssertEqual(search.flatMap(\.items).count, 2)
    }

    func testSidebarCountsAndTitles() {
        let items = [
            make("a.mp4", status: .downloading), make("b.zip", status: .queued, queue: .tonight),
            make("c.zip", status: .completed, queue: .tonight), make("d.pdf", status: .failed),
        ]
        XCTAssertEqual(LibrarySelection.all.count(in: items), 4)
        XCTAssertEqual(LibrarySelection.active.count(in: items), 1)
        XCTAssertEqual(LibrarySelection.category(.archives).count(in: items), 2)
        XCTAssertEqual(LibrarySelection.queue(.tonight).count(in: items), 1)
        XCTAssertEqual(LibrarySelection.queue(.main).count(in: items), 1)
        XCTAssertEqual(ListPresentation.title(selection: .queue(.tonight), search: ""), "Tonight")
        XCTAssertEqual(ListPresentation.title(selection: .all, search: "x"), "Search")
        XCTAssertEqual(ListPresentation.emptyTitle(selection: .all, search: " cats "), "Nothing matches “cats”")
        XCTAssertEqual(LibrarySelection.category(.music).emptyTitle, "No music yet")

        var snapshot = CoordinatorSnapshot(items: items, totalSpeed: 35_400_000, settings: Settings())
        XCTAssertEqual(ListPresentation.subtitle(selection: .all, search: "", snapshot: snapshot), "1 downloading · 35.4 MB/s")
        XCTAssertEqual(ListPresentation.subtitle(selection: .queue(.tonight), search: "", snapshot: snapshot), "Runs 1:00 – 7:00 AM, then lets your Mac sleep")
        XCTAssertEqual(ListPresentation.subtitle(selection: .queue(.main), search: "", snapshot: snapshot), "Runs 3 downloads at a time, the rest wait their turn")
        XCTAssertEqual(ListPresentation.subtitle(selection: .failed, search: "", snapshot: snapshot), "1 item")
        XCTAssertEqual(ListPresentation.subtitle(selection: .all, search: "zip", snapshot: snapshot), "2 matches")
        snapshot.items = [make("b.zip", status: .queued)]
        snapshot.holds = [.battery]
        XCTAssertEqual(ListPresentation.subtitle(selection: .all, search: "", snapshot: snapshot), "Paused on battery power")
        XCTAssertTrue(ListPresentation.pauseAllPauses(snapshot.items))
    }

    func testHLSFractionsFollowSegments() {
        var item = DownloadItem(url: URL(string: "https://v.org/a.m3u8")!, kind: .hls, fileName: "talk.mp4", directory: "/tmp")
        item.connectionCount = 2
        var info = HLSInfo(playlistURL: item.url)
        info.segmentCount = 4
        info.completedSegments = [0, 1, 2]
        item.hls = info
        item.status = .downloading
        XCTAssertEqual(ItemPresentation.fractions(item), [1, 0.5])
        XCTAssertEqual(item.fractionDone, 0.75)
    }
}
