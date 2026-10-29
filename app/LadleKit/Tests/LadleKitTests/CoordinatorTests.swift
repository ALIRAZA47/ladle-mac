import XCTest
@testable import LadleKit

/// Real time, short sleeps, and a wall clock the test can move (for the Tonight window).
final class TestClock: LadleClock, @unchecked Sendable {
    let date: Locked<Date>

    init(date: Date = Date()) {
        self.date = Locked(date)
    }

    func now() -> Date { date.current }
    func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0.001, min(seconds, 0.05)) * 1_000_000_000))
    }
}

final class CoordinatorTests: XCTestCase {
    var folder: TempFolder!
    var server: FakeServer!
    var clock: TestClock!
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUp() {
        folder = TempFolder()
        server = FakeServer()
        // Noon: outside the Tonight window.
        clock = TestClock(date: calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))!)
    }

    var paths: AppPaths { AppPaths(directory: folder.url.appendingPathComponent("Support", isDirectory: true)) }

    func makeCoordinator(settings: Settings = Settings()) -> DownloadCoordinator {
        var s = settings
        s.saveFolderPath = folder.url.appendingPathComponent("Downloads/Ladle").path
        let env = DownloadCoordinator.Environment(
            transport: server, clock: clock, calendar: calendar, home: folder.url,
            tickInterval: 0.02, minPiece: 64 * 1024
        )
        return DownloadCoordinator(paths: paths, settings: s, environment: env)
    }

    func waitUntil(_ what: String = "condition", timeout: Double = 10, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    func add(_ coordinator: DownloadCoordinator, _ url: String, start: StartChoice = .now, checksum: ExpectedChecksum? = nil, conflict: ConflictChoice? = nil) async -> UUID {
        let plans = await coordinator.plan([DownloadRequest(url: URL(string: url)!, checksum: checksum)])
        return await coordinator.add(plans, start: start, conflict: conflict)[0]
    }

    func testDownloadsIntoTheCategoryFolderAndAnnouncesIt() async throws {
        let data = TestData.bytes(700_000)
        server.serve(URL(string: "https://handbrake.fr/HandBrake-1.8.2.dmg")!, FakeFile(data: data, chunkSize: 32 * 1024))
        let coordinator = makeCoordinator()
        await coordinator.start()
        let events = coordinator.events
        let id = await add(coordinator, "https://handbrake.fr/HandBrake-1.8.2.dmg")
        try await waitUntil("completion") { await coordinator.item(id)?.status == .completed }
        let v1 = await coordinator.item(id)
        let item = try XCTUnwrap(v1)
        XCTAssertEqual(item.directory, folder.url.appendingPathComponent("Downloads/Ladle/Apps").path)
        XCTAssertEqual(try Data(contentsOf: item.finalURL), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.partURL.path))
        XCTAssertEqual(item.totalBytes, 700_000)
        XCTAssertEqual(item.connectionCount, 8)
        XCTAssertNotNil(item.finishedAt)
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        guard case .finished(let finished)? = event else { return XCTFail("\(String(describing: event))") }
        XCTAssertEqual(finished.id, id)
        // Saved to Application Support.
        let saved = JSONFileStore<DownloadsFile>(url: paths.downloads).load()
        XCTAssertEqual(saved?.items.first?.status, .completed)
        await coordinator.prepareForQuit()
    }

    func testRunsThreeAtATime() async throws {
        for n in 1...5 {
            server.serve(URL(string: "https://a.org/f\(n).zip")!, FakeFile(data: TestData.bytes(200_000), chunkSize: 8 * 1024, chunkDelay: 0.004))
        }
        let coordinator = makeCoordinator()
        await coordinator.start()
        var ids: [UUID] = []
        for n in 1...5 { ids.append(await add(coordinator, "https://a.org/f\(n).zip")) }
        var most = 0
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let items = await coordinator.allItems
            most = max(most, items.filter { $0.status == .downloading }.count)
            if items.allSatisfy({ $0.status == .completed }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(most, 3)
        let statuses = await coordinator.allItems.map(\.status)
        XCTAssertEqual(statuses, [DownloadStatus](repeating: .completed, count: 5))
        await coordinator.prepareForQuit()
    }

    func testTonightWaitsForTheWindow() async throws {
        server.serve(URL(string: "https://a.org/big.zip")!, FakeFile(data: TestData.bytes(100_000)))
        let coordinator = makeCoordinator()
        await coordinator.start()
        let events = coordinator.events
        let id = await add(coordinator, "https://a.org/big.zip", start: .tonight)
        try await Task.sleep(nanoseconds: 150_000_000)
        let waiting = await coordinator.item(id)
        XCTAssertEqual(waiting?.status, .queued)
        XCTAssertEqual(waiting?.queue, .tonight)
        clock.date.withLock { $0 = self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 1, minute: 5))! }
        try await waitUntil("tonight run") { await coordinator.item(id)?.status == .completed }
        var iterator = events.makeAsyncIterator()
        var sawFinish = false
        for _ in 0..<5 {
            if case .tonightQueueFinished? = await iterator.next() {
                sawFinish = true
                break
            }
        }
        XCTAssertTrue(sawFinish, "the Mac may sleep now")
        await coordinator.prepareForQuit()
    }

    func testPauseResumeKeepsProgressAndFinishesCorrectly() async throws {
        let data = TestData.bytes(1_500_000)
        server.serve(URL(string: "https://a.org/x.iso")!, FakeFile(data: data, chunkSize: 16 * 1024, chunkDelay: 0.003))
        let coordinator = makeCoordinator()
        await coordinator.start()
        let id = await add(coordinator, "https://a.org/x.iso")
        try await waitUntil("some progress") { (await coordinator.item(id)?.receivedBytes ?? 0) > 100_000 }
        await coordinator.pause(id)
        let v2 = await coordinator.item(id)
        let paused = try XCTUnwrap(v2)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertGreaterThan(paused.pieces.reduce(0) { $0 + $1.received }, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.partURL.path))
        let requestsBefore = server.requests.count
        await coordinator.resume(id)
        try await waitUntil("completion") { await coordinator.item(id)?.status == .completed }
        let v3 = await coordinator.item(id)
        let done = try XCTUnwrap(v3)
        XCTAssertEqual(try Data(contentsOf: done.finalURL), data)
        let resumedStarts = server.requests.dropFirst(requestsBefore).compactMap(\.rangeStart)
        XCTAssertFalse(resumedStarts.contains(0), "resume doesn't start from the first byte")
        await coordinator.prepareForQuit()
    }

    func testResumesAfterRelaunch() async throws {
        let data = TestData.bytes(1_200_000)
        server.serve(URL(string: "https://a.org/y.iso")!, FakeFile(data: data, chunkSize: 16 * 1024, chunkDelay: 0.003))
        let first = makeCoordinator()
        await first.start()
        let id = await add(first, "https://a.org/y.iso")
        try await waitUntil("some progress") { (await first.item(id)?.receivedBytes ?? 0) > 100_000 }
        await first.prepareForQuit()
        let saved = JSONFileStore<DownloadsFile>(url: paths.downloads).load()?.items.first
        XCTAssertEqual(saved?.status, .queued, "quit leaves it ready to resume")
        XCTAssertGreaterThan(saved?.pieces.reduce(0) { $0 + $1.received } ?? 0, 0)

        let second = makeCoordinator()
        await second.start()
        try await waitUntil("completion after relaunch") { await second.item(id)?.status == .completed }
        let v4 = await second.item(id)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(v4).finalURL), data)
        await second.prepareForQuit()
    }

    func testKeepBothAndReplace() async throws {
        let target = folder.url.appendingPathComponent("Downloads/Ladle/Documents")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("report.pdf"))
        server.serve(URL(string: "https://a.org/report.pdf")!, FakeFile(data: Data("new".utf8)))
        let coordinator = makeCoordinator()
        await coordinator.start()
        let plan = await coordinator.plan([DownloadRequest(url: URL(string: "https://a.org/report.pdf")!)])
        XCTAssertTrue(plan[0].conflict)
        let keep = await coordinator.add(plan)[0]
        try await waitUntil("keep both") { await coordinator.item(keep)?.status == .completed }
        let v5 = await coordinator.item(keep)?.fileName
        XCTAssertEqual(v5, "report 2.pdf")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("report.pdf"), encoding: .utf8), "old")

        let replace = await coordinator.add(await coordinator.plan([DownloadRequest(url: URL(string: "https://a.org/report.pdf")!)]), conflict: .replace)[0]
        try await waitUntil("replace") { await coordinator.item(replace)?.status == .completed }
        let v6 = await coordinator.item(replace)?.fileName
        XCTAssertEqual(v6, "report.pdf")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("report.pdf"), encoding: .utf8), "new")
        await coordinator.prepareForQuit()
    }

    func testServerNameMovesTheFileToItsCategory() async throws {
        var file = FakeFile(data: TestData.bytes(10_000))
        file.contentDisposition = "attachment; filename=\"annual-report-2025.pdf\""
        server.serve(URL(string: "https://investors.example.com/download?id=3")!, file)
        let coordinator = makeCoordinator()
        await coordinator.start()
        let id = await add(coordinator, "https://investors.example.com/download?id=3")
        let v7 = await coordinator.item(id)?.fileName
        XCTAssertEqual(v7, "download")
        try await waitUntil("completion") { await coordinator.item(id)?.status == .completed }
        let v8 = await coordinator.item(id)
        let item = try XCTUnwrap(v8)
        XCTAssertEqual(item.fileName, "annual-report-2025.pdf")
        XCTAssertEqual(item.category, .documents)
        XCTAssertTrue(item.directory.hasSuffix("Downloads/Ladle/Documents"))
        await coordinator.prepareForQuit()
    }

    func testRemovingADownloadDeletesItsPartFile() async throws {
        server.serve(URL(string: "https://a.org/slow.zip")!, FakeFile(data: TestData.bytes(2_000_000), chunkSize: 8 * 1024, chunkDelay: 0.005))
        let coordinator = makeCoordinator()
        await coordinator.start()
        let id = await add(coordinator, "https://a.org/slow.zip")
        try await waitUntil("running") { (await coordinator.item(id)?.receivedBytes ?? 0) > 0 }
        let v9 = await coordinator.item(id)
        let part = try XCTUnwrap(v9).partURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        await coordinator.remove(id)
        let v10 = await coordinator.item(id)
        XCTAssertNil(v10)
        try await Task.sleep(nanoseconds: 100_000_000)
        let v11 = await coordinator.item(id)
        XCTAssertNil(v11, "nothing restarts it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        await coordinator.prepareForQuit()
    }

    func testChecksums() async throws {
        let data = TestData.bytes(50_000)
        let sha = Checksums.digest(of: data, algorithm: .sha256)
        server.serve(URL(string: "https://a.org/good.iso")!, FakeFile(data: data))
        server.serve(URL(string: "https://a.org/bad.iso")!, FakeFile(data: data))
        server.serve(URL(string: "https://a.org/side.iso")!, FakeFile(data: data))
        server.serve(URL(string: "https://a.org/side.iso.sha256")!, FakeFile(data: Data("\(sha)  side.iso\n".utf8)))
        server.serve(URL(string: "https://a.org/plain.iso")!, FakeFile(data: data))
        let coordinator = makeCoordinator()
        await coordinator.start()
        let good = await add(coordinator, "https://a.org/good.iso", checksum: ExpectedChecksum(algorithm: .sha256, value: sha, source: .pasted))
        let bad = await add(coordinator, "https://a.org/bad.iso", checksum: ExpectedChecksum(algorithm: .md5, value: String(repeating: "0", count: 32), source: .pasted))
        let side = await add(coordinator, "https://a.org/side.iso")
        let plain = await add(coordinator, "https://a.org/plain.iso")
        try await waitUntil("verification") {
            let states = await [coordinator.item(good), coordinator.item(bad), coordinator.item(side), coordinator.item(plain)]
            return states.allSatisfy { $0?.status == .completed && $0?.checksumState != .verifying }
        }
        let v12 = await coordinator.item(good)?.checksumState
        XCTAssertEqual(v12, .verified)
        let v13 = await coordinator.item(bad)?.checksumState
        XCTAssertEqual(v13, .mismatch)
        let v14 = await coordinator.item(side)?.checksumState
        XCTAssertEqual(v14, .verified)
        let v15 = await coordinator.item(side)?.checksum?.source
        XCTAssertEqual(v15, .sidecar)
        let v16 = await coordinator.item(plain)?.checksumState
        XCTAssertNil(v16)
        await coordinator.prepareForQuit()
    }

    func testBatteryHoldsTheTonightQueueOnly() async throws {
        clock.date.withLock { $0 = self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 1, minute: 5))! }
        let data = TestData.bytes(1_000_000)
        server.serve(URL(string: "https://a.org/z.zip")!, FakeFile(data: data, chunkSize: 8 * 1024, chunkDelay: 0.01))
        server.serve(URL(string: "https://a.org/mine.zip")!, FakeFile(data: data, chunkSize: 16 * 1024, chunkDelay: 0.003))
        let coordinator = makeCoordinator()
        await coordinator.start()
        let id = await add(coordinator, "https://a.org/z.zip", start: .tonight)
        try await waitUntil("progress") { (await coordinator.item(id)?.receivedBytes ?? 0) > 50_000 }
        await coordinator.setHold(.battery, active: true)
        let v17 = await coordinator.item(id)?.status
        XCTAssertEqual(v17, .queued)
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.holds, [.battery])
        // Downloads you start yourself always run.
        let mine = await add(coordinator, "https://a.org/mine.zip")
        try await waitUntil("own download") { await coordinator.item(mine)?.status == .completed }
        let v18 = await coordinator.item(id)?.status
        XCTAssertEqual(v18, .queued, "the Tonight queue stays put while on battery")
        await coordinator.setHold(.battery, active: false)
        try await waitUntil("completion") { await coordinator.item(id)?.status == .completed }
        let v19 = await coordinator.item(id)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(v19).finalURL), data)
        await coordinator.prepareForQuit()
    }

    func testLaterAddsWithoutStarting() async throws {
        let data = TestData.bytes(200_000)
        server.serve(URL(string: "https://a.org/later.zip")!, FakeFile(data: data))
        let coordinator = makeCoordinator()
        await coordinator.start()
        let id = await add(coordinator, "https://a.org/later.zip", start: .later)
        try await Task.sleep(nanoseconds: 150_000_000)
        let waiting = await coordinator.item(id)
        XCTAssertEqual(waiting?.status, .paused)
        XCTAssertEqual(waiting?.queue, .main)
        XCTAssertEqual(waiting?.neverStarted, true)
        XCTAssertEqual(waiting.map(ItemPresentation.primaryAction), .start)
        await coordinator.resume(id)
        try await waitUntil("completion") { await coordinator.item(id)?.status == .completed }
        let done = await coordinator.item(id)
        XCTAssertEqual(done?.neverStarted, false)
        await coordinator.prepareForQuit()
    }

    func testFailureRetryAndStartOver() async throws {
        let coordinator = makeCoordinator()
        await coordinator.start()
        let missing = await add(coordinator, "https://a.org/missing.zip")
        try await waitUntil("failure") { await coordinator.item(missing)?.status == .failed }
        let v20 = await coordinator.item(missing)?.failure?.code
        XCTAssertEqual(v20, .notFound)
        server.serve(URL(string: "https://a.org/missing.zip")!, FakeFile(data: Data("now here".utf8)))
        await coordinator.retry(missing)
        try await waitUntil("retry succeeds") { await coordinator.item(missing)?.status == .completed }

        // A file that changes on the server while paused must be started over, by choice.
        let data = TestData.bytes(1_600_000)
        // Slow enough that the pause lands well before the last piece arrives.
        server.serve(URL(string: "https://a.org/changing.bin")!, FakeFile(data: data, chunkSize: 8 * 1024, chunkDelay: 0.01))
        let id = await add(coordinator, "https://a.org/changing.bin")
        try await waitUntil("progress") { (await coordinator.item(id)?.receivedBytes ?? 0) > 50_000 }
        await coordinator.pause(id)
        var changed = FakeFile(data: TestData.bytes(1_600_000, seed: 99))
        changed.etag = "\"v2\""
        server.serve(URL(string: "https://a.org/changing.bin")!, changed)
        await coordinator.resume(id)
        try await waitUntil("asks to start over") { await coordinator.item(id)?.status == .failed }
        let v21 = await coordinator.item(id)?.failure?.code
        XCTAssertEqual(v21, .changedOnServer)
        await coordinator.startOver(id)
        try await waitUntil("fresh download") { await coordinator.item(id)?.status == .completed }
        let v22 = await coordinator.item(id)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(v22).finalURL), TestData.bytes(1_600_000, seed: 99))
        await coordinator.prepareForQuit()
    }

    func testPlanFlagsLinksAlreadyHandled() async throws {
        server.serve(URL(string: "https://a.org/done.pdf")!, FakeFile(data: Data("x".utf8)))
        let coordinator = makeCoordinator()
        await coordinator.start()
        let id = await add(coordinator, "https://a.org/done.pdf")
        try await waitUntil("done") { await coordinator.item(id)?.status == .completed }
        _ = await add(coordinator, "https://a.org/waiting.zip", start: .tonight)
        let plans = await coordinator.plan([
            DownloadRequest(url: URL(string: "https://a.org/done.pdf")!),
            DownloadRequest(url: URL(string: "https://a.org/waiting.zip")!),
            DownloadRequest(url: URL(string: "https://a.org/new.mp3")!),
        ])
        XCTAssertEqual(plans.map(\.alreadyDownloaded), [true, false, false])
        XCTAssertEqual(plans.map(\.alreadyInList), [false, true, false])
        XCTAssertEqual(plans.map(\.isSkippedByDefault), [true, true, false])
        XCTAssertEqual(plans[2].category, .music)
        await coordinator.prepareForQuit()
    }

    func testPauseAllAndResumeAll() async throws {
        for n in 1...4 {
            server.serve(URL(string: "https://a.org/p\(n).zip")!, FakeFile(data: TestData.bytes(400_000), chunkSize: 8 * 1024, chunkDelay: 0.004))
        }
        let coordinator = makeCoordinator()
        await coordinator.start()
        for n in 1...4 { _ = await add(coordinator, "https://a.org/p\(n).zip") }
        try await waitUntil("running") { await coordinator.allItems.filter { $0.status == .downloading }.count == 3 }
        await coordinator.pauseAll()
        let v23 = await coordinator.allItems.map(\.status)
        XCTAssertEqual(Set(v23), [.paused])
        let hasWork = await coordinator.hasActiveWork
        XCTAssertFalse(hasWork)
        await coordinator.resumeAll()
        try await waitUntil("all done") { await coordinator.allItems.allSatisfy { $0.status == .completed } }
        await coordinator.prepareForQuit()
    }

    func testHLSWithSeparateAudioKeepsTwoFilesWithoutAMuxer() async throws {
        let root = "https://v.example.org/t/"
        func serve(_ name: String, _ body: String) {
            server.serve(URL(string: root + name)!, FakeFile(data: Data(body.utf8), etag: nil, lastModified: nil))
        }
        serve("video.m3u8", "#EXTM3U\n#EXT-X-MAP:URI=\"v.mp4\"\n#EXTINF:4,\nv1.m4s\n#EXT-X-ENDLIST\n")
        serve("audio.m3u8", "#EXTM3U\n#EXT-X-MAP:URI=\"a.mp4\"\n#EXTINF:4,\na1.m4s\n#EXT-X-ENDLIST\n")
        for name in ["v.mp4", "v1.m4s", "a.mp4", "a1.m4s"] { serve(name, name) }
        let coordinator = makeCoordinator()
        await coordinator.start()
        let request = DownloadRequest(
            url: URL(string: root + "video.m3u8")!, kind: .hls, title: "Designing for Speed",
            audioURL: URL(string: root + "audio.m3u8")!, quality: "1080p"
        )
        let id = await coordinator.add(await coordinator.plan([request]))[0]
        try await waitUntil("completion") { await coordinator.item(id)?.status == .completed }
        let v24 = await coordinator.item(id)
        let item = try XCTUnwrap(v24)
        XCTAssertEqual(item.fileName, "Designing for Speed.mp4")
        XCTAssertEqual(try String(contentsOf: item.finalURL, encoding: .utf8), "v.mp4v1.m4s")
        let audio = URL(fileURLWithPath: item.directory).appendingPathComponent("Designing for Speed (audio).m4a")
        XCTAssertEqual(try String(contentsOf: audio, encoding: .utf8), "a.mp4a1.m4s")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.partURL.path))
        await coordinator.prepareForQuit()
    }

    func testInspectsLinks() async throws {
        var file = FakeFile(data: TestData.bytes(642_000))
        file.contentDisposition = "attachment; filename=big-buck-bunny-2160p.mp4"
        server.serve(URL(string: "https://media.example.org/get?f=1")!, file)
        let coordinator = makeCoordinator()
        let found = await coordinator.inspect(URL(string: "https://media.example.org/get?f=1")!)
        XCTAssertEqual(found.fileName, "big-buck-bunny-2160p.mp4")
        XCTAssertEqual(found.size, 642_000)
        XCTAssertTrue(found.resumable)
        XCTAssertNil(found.failure)
        let missing = await coordinator.inspect(URL(string: "https://media.example.org/none.mp4")!)
        XCTAssertEqual(missing.failure?.code, .notFound)
        XCTAssertEqual(missing.fileName, "none.mp4")
    }
}
