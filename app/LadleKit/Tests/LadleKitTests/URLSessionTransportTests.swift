import XCTest
@testable import LadleKit

/// The real URLSession transport against a local server.
final class URLSessionTransportTests: XCTestCase {
    var server: LocalHTTPServer!
    var transport: URLSessionTransport!

    override func setUpWithError() throws {
        server = try LocalHTTPServer()
        transport = URLSessionTransport()
    }

    override func tearDown() {
        transport.invalidate()
        server.stop()
    }

    func testRangeRequest() async throws {
        let data = TestData.bytes(100_000)
        server.route("/a.bin", .init(body: data))
        let response = try await transport.open(HTTPRequest(url: server.url("/a.bin"), rangeStart: 10, rangeEnd: 19))
        XCTAssertEqual(response.head.statusCode, 206)
        XCTAssertEqual(response.head.contentRange, ContentRange(start: 10, end: 19, total: 100_000))
        XCTAssertEqual(response.head.validator.etag, "\"local\"")
        var body = Data()
        while let chunk = try await response.body.next() { body.append(chunk) }
        XCTAssertEqual(body, data.subdata(in: 10..<20))
    }

    func testSegmentedDownloadOverRealConnections() async throws {
        let data = TestData.bytes(3_000_000)
        server.route("/ubuntu.iso", .init(body: data))
        let folder = TempFolder()
        let job = FileJob(url: server.url("/ubuntu.iso"), partURL: folder.file("ubuntu.iso.ladle-part"), connections: 8, retryLimit: 3, minPiece: 128 * 1024)
        let downloader = FileDownloader(job: job, transport: transport, limiter: TokenBucket(bytesPerSecond: nil), throttle: HostThrottle()) { _ in job.partURL }
        let outcome = await downloader.run()
        XCTAssertEqual(outcome, .completed(total: 3_000_000))
        XCTAssertEqual(try Data(contentsOf: job.partURL), data)
        let ranges = server.received.current.compactMap { $0.headers["range"] }
        XCTAssertGreaterThanOrEqual(ranges.count, 8)
    }

    func testCookiesStayWithTheirHostAcrossRedirects() async throws {
        let data = Data("payload".utf8)
        server.route("/file.zip", .init(body: data))
        // 127.0.0.1 redirects to localhost: a different host.
        server.route("/go", .init(body: Data(), redirect: server.url("/file.zip", host: "localhost").absoluteString))
        let request = HTTPRequest(url: server.url("/go"), rangeStart: 2, cookies: "session=secret", referrer: server.url("/page"))
        let response = try await transport.open(request)
        var body = Data()
        while let chunk = try await response.body.next() { body.append(chunk) }
        XCTAssertEqual(body, Data("yload".utf8))
        let log = server.received.current
        let first = try XCTUnwrap(log.first { $0.path == "/go" })
        let second = try XCTUnwrap(log.first { $0.path == "/file.zip" })
        XCTAssertEqual(first.headers["cookie"], "session=secret")
        XCTAssertEqual(first.headers["referer"], server.url("/page").absoluteString)
        XCTAssertNil(second.headers["cookie"], "cookies are only for the download's own host")
        XCTAssertNil(second.headers["referer"])
        XCTAssertEqual(second.headers["range"], "bytes=2-", "the range survives the redirect")
    }

    func testCancellingAReadStopsTheTask() async throws {
        server.route("/big", .init(body: TestData.bytes(5_000_000)))
        let response = try await transport.open(HTTPRequest(url: server.url("/big")))
        _ = try await response.body.next()
        response.body.cancel()
        do {
            while try await response.body.next() != nil {}
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testSpeedLimitThrottlesRealConnections() async throws {
        // Slow reading fills the transport's buffer, which suspends the task until it drains.
        let data = TestData.bytes(3_000_000)
        server.route("/limited.bin", .init(body: data))
        let folder = TempFolder()
        let job = FileJob(url: server.url("/limited.bin"), partURL: folder.file("limited.ladle-part"), connections: 4, retryLimit: 3, minPiece: 256 * 1024)
        let limiter = TokenBucket(bytesPerSecond: 3_000_000)
        let downloader = FileDownloader(job: job, transport: transport, limiter: limiter, throttle: HostThrottle()) { _ in job.partURL }
        let started = Date()
        let outcome = await downloader.run()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome, .completed(total: 3_000_000))
        XCTAssertEqual(try Data(contentsOf: job.partURL), data)
        XCTAssertGreaterThan(elapsed, 0.7, "3 MB at 3 MB/s, minus the burst allowance")
        XCTAssertLessThan(elapsed, 4)
    }

    func testMissingFile() async throws {
        let response = try await transport.open(HTTPRequest(url: server.url("/nope")))
        XCTAssertEqual(response.head.statusCode, 404)
    }

    func testUnreachableHostIsAnError() async {
        do {
            _ = try await transport.open(HTTPRequest(url: URL(string: "http://127.0.0.1:1/x")!, timeout: 5))
            XCTFail("expected an error")
        } catch {
            XCTAssertNotNil(error as? TransportError)
        }
    }
}
