import XCTest
@testable import LadleKit

final class FileDownloaderTests: XCTestCase {
    let url = URL(string: "https://files.example.com/share/brand-assets-2026.zip")!
    let small: Int64 = 64 * 1024

    private func makeDownloader(
        server: FakeServer,
        part: URL,
        job: FileJob? = nil,
        connections: Int = 8,
        retryLimit: Int = 3,
        limiter: TokenBucket = TokenBucket(bytesPerSecond: nil),
        throttle: HostThrottle = HostThrottle(clock: FastClock()),
        probes: Locked<[ProbeInfo]> = Locked([])
    ) -> FileDownloader {
        let job = job ?? FileJob(url: url, partURL: part, connections: connections, retryLimit: retryLimit, minPiece: small)
        return FileDownloader(job: job, transport: server, limiter: limiter, throttle: throttle, clock: FastClock()) { info in
            probes.withLock { $0.append(info) }
            return part
        }
    }

    func testDownloadsWholeFileOverEightConnections() async throws {
        let folder = TempFolder()
        let data = TestData.bytes(2_000_000)
        let server = FakeServer()
        server.serve(url, FakeFile(data: data, chunkSize: 16 * 1024, chunkDelay: 0.001))
        let part = folder.file("brand-assets-2026.zip.ladle-part")
        let probes = Locked<[ProbeInfo]>([])
        let downloader = makeDownloader(server: server, part: part, probes: probes)

        let outcome = await downloader.run()

        XCTAssertEqual(outcome, .completed(total: Int64(data.count)))
        XCTAssertEqual(try Data(contentsOf: part), data)
        XCTAssertEqual(probes.current.first?.resumable, true)
        XCTAssertEqual(probes.current.first?.total, Int64(data.count))
        XCTAssertEqual(probes.current.first?.validator.etag, "\"v1\"")
        let ranges = server.requests.compactMap(\.rangeStart)
        XCTAssertGreaterThanOrEqual(ranges.count, 8, "one request per connection at least")
        XCTAssertEqual(server.requests.first?.rangeHeader, "bytes=0-")
        XCTAssertEqual(Set(server.requests.map(\.connectionSlot)).count, 8)
        let progress = downloader.progress()
        XCTAssertEqual(progress.received, Int64(data.count))
        XCTAssertEqual(progress.pieces.count, 1, "finished pieces are merged")
    }

    func testFallsBackToOneConnectionWithoutRangeSupport() async throws {
        let folder = TempFolder()
        let data = TestData.bytes(500_000)
        let server = FakeServer()
        server.serve(url, FakeFile(data: data, supportsRanges: false))
        let part = folder.file("x.ladle-part")
        let probes = Locked<[ProbeInfo]>([])
        let downloader = makeDownloader(server: server, part: part, probes: probes)

        let outcome = await downloader.run()

        XCTAssertEqual(outcome, .completed(total: Int64(data.count)))
        XCTAssertEqual(try Data(contentsOf: part), data)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(probes.current.first?.resumable, false)
    }

    func testDownloadsFileOfUnknownSize() async throws {
        let folder = TempFolder()
        let data = TestData.bytes(300_001)
        let server = FakeServer()
        server.serve(url, FakeFile(data: data, supportsRanges: false, sendsLength: false))
        let part = folder.file("x.ladle-part")
        let probes = Locked<[ProbeInfo]>([])
        let downloader = makeDownloader(server: server, part: part, probes: probes)

        let outcome = await downloader.run()

        XCTAssertEqual(outcome, .completed(total: Int64(data.count)))
        XCTAssertEqual(try Data(contentsOf: part), data)
        XCTAssertNil(probes.current.first?.total)
        XCTAssertEqual(downloader.progress().total, Int64(data.count))
    }

    func testEmptyFile() async throws {
        let folder = TempFolder()
        let server = FakeServer()
        server.serve(url, FakeFile(data: Data()))
        let part = folder.file("x.ladle-part")
        let outcome = await makeDownloader(server: server, part: part).run()
        XCTAssertEqual(outcome, .completed(total: 0))
        XCTAssertEqual(try Data(contentsOf: part).count, 0)
    }

    func testResumesFromSavedPiecesWithoutRefetchingFinishedBytes() async throws {
        let folder = TempFolder()
        let data = TestData.bytes(1_000_000)
        let server = FakeServer()
        server.serve(url, FakeFile(data: data))
        let part = folder.file("x.ladle-part")
        // Simulate an earlier run that wrote the first half of each of two pieces.
        let file = try PartFile(url: part, truncate: true)
        try file.preallocate(size: Int64(data.count))
        try file.write(data.subdata(in: 0..<200_000), at: 0)
        try file.write(data.subdata(in: 500_000..<650_000), at: 500_000)
        file.close()
        let pieces = [Piece(start: 0, end: 500_000, received: 200_000), Piece(start: 500_000, end: 1_000_000, received: 150_000)]
        let job = FileJob(
            url: url, partURL: part, pieces: pieces, total: Int64(data.count),
            validator: Validator(etag: "\"v1\"", lastModified: nil, size: Int64(data.count)),
            resumable: true, connections: 2, retryLimit: 3, minPiece: small
        )

        let outcome = await makeDownloader(server: server, part: part, job: job).run()

        XCTAssertEqual(outcome, .completed(total: Int64(data.count)))
        XCTAssertEqual(try Data(contentsOf: part), data)
        let starts = server.requests.compactMap(\.rangeStart)
        XCTAssertEqual(starts.first, 200_000, "probe starts at the first missing byte")
        XCTAssertFalse(starts.contains { $0 < 200_000 })
        XCTAssertFalse(starts.contains { $0 >= 500_000 && $0 < 650_000 })
    }

    func testRefusesToResumeWhenTheFileChanged() async throws {
        let folder = TempFolder()
        let data = TestData.bytes(400_000)
        let server = FakeServer()
        var changed = FakeFile(data: data)
        changed.etag = "\"v2\""
        server.serve(url, changed)
        let part = folder.file("x.ladle-part")
        let file = try PartFile(url: part, truncate: true)
        try file.preallocate(size: 400_000)
        file.close()
        let job = FileJob(
            url: url, partURL: part, pieces: [Piece(start: 0, end: 400_000, received: 100_000)], total: 400_000,
            validator: Validator(etag: "\"v1\"", size: 400_000), resumable: true, connections: 2, minPiece: small
        )
        let outcome = await makeDownloader(server: server, part: part, job: job).run()
        XCTAssertEqual(outcome, .failed(DownloadFailure(.changedOnServer)))
    }

    func testRefusesToResumeWhenServerDropsRangeSupport() async throws {
        let folder = TempFolder()
        let server = FakeServer()
        server.serve(url, FakeFile(data: TestData.bytes(400_000), supportsRanges: false))
        let part = folder.file("x.ladle-part")
        try PartFile(url: part, truncate: true).preallocate(size: 400_000)
        let job = FileJob(
            url: url, partURL: part, pieces: [Piece(start: 0, end: 400_000, received: 100_000)], total: 400_000,
            validator: Validator(etag: "\"v1\"", size: 400_000), resumable: true, connections: 2, minPiece: small
        )
        let outcome = await makeDownloader(server: server, part: part, job: job).run()
        XCTAssertEqual(outcome, .failed(DownloadFailure(.cannotResume)))
    }

    func testNonResumableProgressNeedsStartOver() async throws {
        let folder = TempFolder()
        let server = FakeServer()
        let part = folder.file("x.ladle-part")
        let job = FileJob(url: url, partURL: part, pieces: [Piece(start: 0, end: 100, received: 50)], total: 100, resumable: false)
        let outcome = await makeDownloader(server: server, part: part, job: job).run()
        XCTAssertEqual(outcome, .failed(DownloadFailure(.cannotResume)))
        XCTAssertTrue(server.requests.isEmpty, "asks before starting over, never silently")
    }

    func testRetriesDroppedConnections() async throws {
        let folder = TempFolder()
        let data = TestData.bytes(800_000)
        let server = FakeServer()
        server.serve(url, FakeFile(data: data, chunkSize: 32 * 1024))
        server.inject(.dropAfter(bytes: 50_000), times: 3) { $0.rangeStart != nil && $0.rangeStart! > 0 }
        let part = folder.file("x.ladle-part")
        let downloader = makeDownloader(server: server, part: part, connections: 4)
        let outcome = await downloader.run()
        XCTAssertEqual(outcome, .completed(total: Int64(data.count)))
        XCTAssertEqual(try Data(contentsOf: part), data)
        XCTAssertGreaterThanOrEqual(downloader.attempts, 1)
    }

    func testGivesUpAfterRetryLimit() async throws {
        let folder = TempFolder()
        let server = FakeServer()
        server.serve(url, FakeFile(data: TestData.bytes(10_000)))
        server.inject(.status(500, headers: [:]), times: 100)
        let downloader = makeDownloader(server: server, part: folder.file("x.ladle-part"), retryLimit: 3)
        let outcome = await downloader.run()
        XCTAssertEqual(outcome, .failed(DownloadFailure(.serverError, httpStatus: 500)))
        XCTAssertEqual(server.requests.count, 4, "first try plus three retries")
        XCTAssertEqual(downloader.attempts, 4)
    }

    func testNeverRetryMeansOneTry() async throws {
        let folder = TempFolder()
        let server = FakeServer()
        server.serve(url, FakeFile(data: TestData.bytes(10_000)))
        server.inject(.transportError(.timedOut), times: 100)
        let outcome = await makeDownloader(server: server, part: folder.file("x.ladle-part"), retryLimit: 0).run()
        XCTAssertEqual(outcome, .failed(DownloadFailure(.timedOut)))
        XCTAssertEqual(server.requests.count, 1)
    }

    func testMissingFileFailsWithoutRetrying() async throws {
        let folder = TempFolder()
        let server = FakeServer()
        let outcome = await makeDownloader(server: server, part: folder.file("x.ladle-part")).run()
        XCTAssertEqual(outcome, .failed(DownloadFailure(.notFound, httpStatus: 404)))
        XCTAssertEqual(server.requests.count, 1)
    }

    func testBacksOffAndHalvesConnectionsOn503() async throws {
        let folder = TempFolder()
        let data = TestData.bytes(1_000_000)
        let server = FakeServer()
        server.serve(url, FakeFile(data: data, chunkSize: 16 * 1024))
        server.inject(.status(503, headers: ["Retry-After": "2"]), times: 2) { ($0.rangeStart ?? 0) > 0 }
        let throttle = HostThrottle(clock: FastClock())
        let part = folder.file("x.ladle-part")
        let outcome = await makeDownloader(server: server, part: part, connections: 8, throttle: throttle).run()
        XCTAssertEqual(outcome, .completed(total: Int64(data.count)))
        XCTAssertEqual(try Data(contentsOf: part), data)
        XCTAssertLessThan(throttle.allowedConnections(host: "files.example.com", wanted: 8), 8)
    }

    func testFinishedConnectionTakesHalfOfTheLargestPiece() async throws {
        let folder = TempFolder()
        let data = TestData.bytes(1_024 * 1024)
        let server = FakeServer()
        server.serve(url, FakeFile(data: data, chunkSize: 8 * 1024))
        // The second half of the file pours slowly, so the first connection finishes early.
        server.slowFrom.withLock { $0 = (offset: 512 * 1024, delay: 0.002) }
        let part = folder.file("x.ladle-part")
        let outcome = await makeDownloader(server: server, part: part, connections: 2).run()
        XCTAssertEqual(outcome, .completed(total: Int64(data.count)))
        XCTAssertEqual(try Data(contentsOf: part), data)
        let laterStarts = server.requests.compactMap(\.rangeStart).filter { $0 > 512 * 1024 }
        XCTAssertFalse(laterStarts.isEmpty, "a split piece was requested from the middle of the slow half")
    }

    func testCancelLeavesSavableProgress() async throws {
        let folder = TempFolder()
        let data = TestData.bytes(2_000_000)
        let server = FakeServer()
        server.serve(url, FakeFile(data: data, chunkSize: 16 * 1024, chunkDelay: 0.005))
        let part = folder.file("x.ladle-part")
        let downloader = makeDownloader(server: server, part: part, connections: 4)
        let task = Task { await downloader.run() }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        let pieces = try XCTUnwrap(downloader.checkpoint())
        let saved = pieces.reduce(Int64(0)) { $0 + $1.received }
        XCTAssertGreaterThan(saved, 0)
        XCTAssertLessThan(saved, Int64(data.count))
        // Every byte the pieces claim is really in the file.
        let written = try Data(contentsOf: part)
        for piece in pieces where piece.received > 0 {
            let range = Int(piece.start)..<Int(piece.start + piece.received)
            XCTAssertEqual(written.subdata(in: range), data.subdata(in: range))
        }
        // And resuming from them finishes the file.
        let job = FileJob(url: url, partURL: part, pieces: pieces, total: Int64(data.count),
                          validator: Validator(etag: "\"v1\"", lastModified: "Tue, 01 Oct 2024 10:00:00 GMT", size: Int64(data.count)),
                          resumable: true, connections: 4, minPiece: small)
        let resumed = await makeDownloader(server: server, part: part, job: job).run()
        XCTAssertEqual(resumed, .completed(total: Int64(data.count)))
        XCTAssertEqual(try Data(contentsOf: part), data)
    }

    func testSpeedLimitSlowsTheTransfer() async throws {
        let folder = TempFolder()
        let data = TestData.bytes(600_000)
        let server = FakeServer()
        server.serve(url, FakeFile(data: data, chunkSize: 16 * 1024))
        let limiter = TokenBucket(bytesPerSecond: 1_000_000, clock: SystemClock())
        let job = FileJob(url: url, partURL: folder.file("x.ladle-part"), connections: 4, minPiece: small)
        let downloader = FileDownloader(job: job, transport: server, limiter: limiter, throttle: HostThrottle(), clock: SystemClock()) { _ in job.partURL }
        let started = Date()
        let outcome = await downloader.run()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome, .completed(total: 600_000))
        // 600 kB at 1 MB/s with a 250 kB burst allowance takes at least ~0.35 s.
        XCTAssertGreaterThan(elapsed, 0.3)
    }

    func testSendsCookiesAndReferrerOnlyToTheDownloadHost() {
        let request = HTTPRequest(
            url: URL(string: "https://example.com/f.zip")!,
            rangeStart: 10, cookies: "a=1", referrer: URL(string: "https://example.com/page")!
        )
        let same = request.headers(for: URL(string: "https://example.com/other")!)
        XCTAssertEqual(same["Cookie"], "a=1")
        XCTAssertEqual(same["Referer"], "https://example.com/page")
        XCTAssertEqual(same["Range"], "bytes=10-")
        let cdn = request.headers(for: URL(string: "https://cdn.example.net/f.zip")!)
        XCTAssertNil(cdn["Cookie"])
        XCTAssertNil(cdn["Referer"])
        XCTAssertEqual(cdn["Range"], "bytes=10-", "the range survives the redirect")
    }
}
