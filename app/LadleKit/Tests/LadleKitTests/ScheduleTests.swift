import XCTest
@testable import LadleKit

final class ScheduleTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// 2026-10-28 is a Wednesday.
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testDefaultWindowIsOneToSevenEveryDay() {
        let window = TonightWindow(settings: Settings())
        XCTAssertFalse(window.isActive(at: date(28, 0, 59), calendar: calendar))
        XCTAssertTrue(window.isActive(at: date(28, 1, 0), calendar: calendar))
        XCTAssertTrue(window.isActive(at: date(28, 6, 59), calendar: calendar))
        XCTAssertFalse(window.isActive(at: date(28, 7, 0), calendar: calendar))
        XCTAssertEqual(window.nextStart(after: date(28, 9), calendar: calendar), date(29, 1))
        XCTAssertEqual(window.nextStart(after: date(28, 0, 30), calendar: calendar), date(28, 1))
    }

    func testDaysOfWeek() {
        // Weekdays only (Mon=2 … Fri=6).
        let window = TonightWindow(startMinute: 60, stopMinute: 420, days: [2, 3, 4, 5, 6])
        XCTAssertTrue(window.isActive(at: date(28, 2), calendar: calendar)) // Wednesday
        XCTAssertFalse(window.isActive(at: date(31, 2), calendar: calendar)) // Saturday
        XCTAssertEqual(window.nextStart(after: date(30, 9), calendar: calendar), date(26 + 7, 1), "Friday morning → Monday 1 AM")
        XCTAssertFalse(TonightWindow(startMinute: 60, stopMinute: 420, days: []).isActive(at: date(28, 2), calendar: calendar))
        XCTAssertNil(TonightWindow(startMinute: 60, stopMinute: 420, days: []).nextStart(after: date(28, 2), calendar: calendar))
    }

    func testWindowAcrossMidnightBelongsToItsStartDay() {
        // 11 PM to 6 AM, Wednesday nights only (weekday 4).
        let window = TonightWindow(startMinute: 23 * 60, stopMinute: 6 * 60, days: [4])
        XCTAssertTrue(window.isActive(at: date(28, 23, 30), calendar: calendar))   // Wed 11:30 PM
        XCTAssertTrue(window.isActive(at: date(29, 3), calendar: calendar))        // Thu 3 AM, Wednesday's night
        XCTAssertFalse(window.isActive(at: date(28, 3), calendar: calendar))       // Wed 3 AM belongs to Tuesday
        XCTAssertFalse(window.isActive(at: date(29, 12), calendar: calendar))
    }

    func testLabels() {
        XCTAssertEqual(TonightWindow.timeLabel(minute: 60), "1:00 AM")
        XCTAssertEqual(TonightWindow.timeLabel(minute: 0), "12:00 AM")
        XCTAssertEqual(TonightWindow.timeLabel(minute: 13 * 60 + 5), "1:05 PM")
        XCTAssertEqual(TonightWindow.shortLabel(minute: 60), "1 AM")
        XCTAssertEqual(TonightWindow.shortLabel(minute: 90), "1:30 AM")
        XCTAssertEqual(TonightWindow(settings: Settings()).rangeLabel, "1:00 – 7:00 AM")
        XCTAssertEqual(TonightWindow(startMinute: 23 * 60, stopMinute: 420, days: [1]).rangeLabel, "11:00 PM – 7:00 AM")
    }

    private func item(_ name: String, _ status: DownloadStatus, queue: QueueKind = .main, manual: Bool = false, added: TimeInterval = 0) -> DownloadItem {
        var item = DownloadItem(url: URL(string: "https://a.org/\(name)")!, fileName: name, directory: "/tmp", queue: queue, addedAt: Date(timeIntervalSince1970: added))
        item.status = status
        item.manualStart = manual
        return item
    }

    func testMainQueueRunsUpToTheLimitInOrder() {
        let items = (1...5).map { item("f\($0).zip", .queued, added: Double($0)) }
        let plan = Scheduler.plan(items: items, settings: Settings(), holds: [], now: date(28, 12), calendar: calendar)
        XCTAssertEqual(plan.start, Array(items.prefix(3).map(\.id)))
        XCTAssertTrue(plan.stop.isEmpty)
    }

    func testFreeSlotsOnly() {
        let items = [item("a", .downloading), item("b", .downloading), item("c", .queued), item("d", .queued)]
        let plan = Scheduler.plan(items: items, settings: Settings(), holds: [], now: date(28, 12), calendar: calendar)
        XCTAssertEqual(plan.start, [items[2].id])
    }

    func testTonightWaitsForItsWindowAndStopsAtSeven() {
        let tonight = item("big.zip", .queued, queue: .tonight)
        XCTAssertTrue(Scheduler.plan(items: [tonight], settings: Settings(), holds: [], now: date(28, 23), calendar: calendar).start.isEmpty)
        XCTAssertEqual(Scheduler.plan(items: [tonight], settings: Settings(), holds: [], now: date(29, 1, 5), calendar: calendar).start, [tonight.id])
        let running = item("big.zip", .downloading, queue: .tonight)
        XCTAssertEqual(Scheduler.plan(items: [running], settings: Settings(), holds: [], now: date(29, 7), calendar: calendar).stop, [running.id])
        XCTAssertEqual(
            Scheduler.waitReason(for: tonight, settings: Settings(), holds: [], now: date(28, 23), calendar: calendar),
            .tonight(startMinute: 60)
        )
    }

    func testHoldsStopEverythingButHandStartedDownloads() {
        let auto = item("a", .downloading)
        let manual = item("b", .downloading, manual: true)
        let waiting = item("c", .queued)
        let plan = Scheduler.plan(items: [auto, manual, waiting], settings: Settings(), holds: [.battery], now: date(28, 12), calendar: calendar)
        XCTAssertEqual(plan.stop, [auto.id])
        XCTAssertTrue(plan.start.isEmpty)
        XCTAssertEqual(Scheduler.waitReason(for: waiting, settings: Settings(), holds: [.battery, .lowData], now: date(28, 12), calendar: calendar), .hold(.battery))
    }

    func testHandStartedRunsPastTheLimit() {
        var items = (1...3).map { item("f\($0)", .downloading) }
        items.append(item("now", .queued, queue: .tonight, manual: true))
        let plan = Scheduler.plan(items: items, settings: Settings(), holds: [], now: date(28, 12), calendar: calendar)
        XCTAssertEqual(plan.start, [items[3].id])
    }

    func testLoweringTheLimitStopsTheNewest() {
        var settings = Settings()
        settings.maxConcurrentDownloads = 1
        let items = [item("a", .downloading), item("b", .downloading), item("c", .downloading)]
        let plan = Scheduler.plan(items: items, settings: settings, holds: [], now: date(28, 12), calendar: calendar)
        XCTAssertEqual(plan.stop, [items[1].id, items[2].id])
    }
}

final class SettingsTests: XCTestCase {
    func testDefaultsMatchTheSpec() {
        let s = Settings()
        XCTAssertTrue(s.openAtLogin)
        XCTAssertTrue(s.showInMenuBar)
        XCTAssertTrue(s.watchClipboard)
        XCTAssertEqual(s.appearance, .auto)
        XCTAssertTrue(s.notifyWhenFinished)
        XCTAssertFalse(s.playSound)
        XCTAssertTrue(s.sortIntoCategoryFolders)
        XCTAssertEqual(s.duplicatePolicy, .keepBoth)
        XCTAssertEqual(s.finishAction, .notify)
        XCTAssertTrue(s.verifyChecksums)
        XCTAssertEqual(s.maxConcurrentDownloads, 3)
        XCTAssertEqual(s.connectionsPerDownload, 8)
        XCTAssertFalse(s.limitSpeed)
        XCTAssertEqual(s.speedLimitBytesPerSecond, 10_000_000)
        XCTAssertEqual(s.retryLimit, 3)
        XCTAssertEqual(s.proxy, .system)
        XCTAssertEqual(s.catchFileTypes, ["dmg", "pkg", "zip", "iso", "mp4", "mov", "mkv", "mp3", "flac", "pdf"])
        XCTAssertTrue(s.askBeforeDownloading)
        XCTAssertEqual(s.tonightStartMinute, 60)
        XCTAssertEqual(s.tonightStopMinute, 420)
        XCTAssertEqual(s.tonightDays, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(s.whenTonightFinishes, .sleep)
        XCTAssertTrue(s.pauseOnBattery)
        XCTAssertTrue(s.pauseOnLowData)
        XCTAssertEqual(s.saveFolder(home: URL(fileURLWithPath: "/Users/a")).path, "/Users/a/Downloads/Ladle")
        XCTAssertEqual(s.duplicatePolicy.title, "Keep both")
        XCTAssertEqual(s.finishAction.title, "Just notify me")
        XCTAssertEqual(s.proxy.title, "Same as macOS")
        XCTAssertEqual(s.whenTonightFinishes.title, "Put the Mac to sleep")
    }

    func testDecodingFillsMissingKeysWithDefaults() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"playSound":true,"connectionsPerDownload":64,"retryLimit":4,"catchFileTypes":[".ZIP","zip"],"appearance":"sepia"}"#.utf8))
        XCTAssertTrue(decoded.playSound)
        XCTAssertEqual(decoded.connectionsPerDownload, 32, "clamped to 1–32")
        XCTAssertEqual(decoded.retryLimit, 3, "snapped to an allowed choice")
        XCTAssertEqual(decoded.catchFileTypes, ["zip"])
        XCTAssertEqual(decoded.appearance, .auto, "unknown values fall back")
        XCTAssertTrue(decoded.showInMenuBar)
    }

    func testRoundTrip() throws {
        var s = Settings()
        s.tonightDays = [2, 3]
        s.alwaysDownloadTypes = ["dmg"]
        s.duplicatePolicy = .ask
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertFalse(back.shouldAsk(forExtension: "DMG"))
        XCTAssertTrue(back.shouldAsk(forExtension: "zip"))
    }

    func testNormalizesRanges() {
        var s = Settings()
        s.maxConcurrentDownloads = 0
        s.connectionsPerDownload = 100
        s.tonightStartMinute = -60
        s.tonightDays = [9, 1, 1]
        let n = s.normalized()
        XCTAssertEqual(n.maxConcurrentDownloads, 1)
        XCTAssertEqual(n.connectionsPerDownload, 32)
        XCTAssertEqual(n.tonightStartMinute, 1380)
        XCTAssertEqual(n.tonightDays, [1])
    }

    func testJSONStoreIsAtomicAndSetsAsideBadFiles() throws {
        let folder = TempFolder()
        let store = JSONFileStore<Settings>(url: folder.file("nested/settings.json"))
        XCTAssertNil(store.load())
        var s = Settings()
        s.playSound = true
        try store.save(s)
        XCTAssertEqual(store.load(), s)
        try Data("{ broken".utf8).write(to: store.url)
        XCTAssertNil(store.load())
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.file("nested").path)
        XCTAssertTrue(leftovers.contains { $0.hasPrefix("settings.unreadable-") }, "the bad file is kept for inspection")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testDownloadsFileRoundTrip() throws {
        let folder = TempFolder()
        let store = JSONFileStore<DownloadsFile>(url: folder.file("downloads.json"))
        var item = DownloadItem(url: URL(string: "https://a.org/x.iso")!, fileName: "x.iso", directory: "/tmp", addedAt: Date(timeIntervalSince1970: 1_800_000_000))
        item.pieces = [Piece(start: 0, end: 10, received: 4)]
        item.validator = Validator(etag: "\"e\"", size: 10)
        item.checksum = ExpectedChecksum(algorithm: .md5, value: String(repeating: "a", count: 32), source: .pasted)
        item.failure = DownloadFailure(.serverError, httpStatus: 502)
        try store.save(DownloadsFile(items: [item]))
        XCTAssertEqual(store.load()?.items, [item])
    }
}
