import Foundation
@testable import LadleKit

/// Sleeps a scaled-down amount so backoff and polling don't slow the tests.
struct FastClock: LadleClock {
    var scale: Double = 0.001

    func now() -> Date { Date() }
    func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds * scale) * 1_000_000_000))
    }
}

/// A file served by `FakeServer`.
struct FakeFile {
    var data: Data
    var supportsRanges = true
    var sendsLength = true
    var etag: String? = "\"v1\""
    var lastModified: String? = "Tue, 01 Oct 2024 10:00:00 GMT"
    var contentDisposition: String?
    var contentType: String? = "application/octet-stream"
    var chunkSize = 64 * 1024
    var chunkDelay: Double = 0
}

/// What the server should do with one request, before serving normally.
enum FakeFault {
    case status(Int, headers: [String: String])
    case dropAfter(bytes: Int)
    case transportError(TransportError)
    case ignoreRange
}

/// An in-memory HTTP server for engine tests. Records every request.
final class FakeServer: HTTPTransport, @unchecked Sendable {
    private let files = Locked<[String: FakeFile]>([:])
    private let faults = Locked<[(match: (HTTPRequest) -> Bool, fault: FakeFault, remaining: Int)]>([])
    let log = Locked<[HTTPRequest]>([])
    /// Bytes from this offset on are served slowly (to provoke dynamic splitting).
    let slowFrom = Locked<(offset: Int64, delay: Double)?>(nil)

    func serve(_ url: URL, _ file: FakeFile) {
        files.withLock { $0[url.absoluteString] = file }
    }

    func inject(_ fault: FakeFault, times: Int = 1, when match: @escaping (HTTPRequest) -> Bool = { _ in true }) {
        faults.withLock { $0.append((match, fault, times)) }
    }

    var requests: [HTTPRequest] { log.current }

    private func takeFault(for request: HTTPRequest) -> FakeFault? {
        faults.withLock { list -> FakeFault? in
            guard let index = list.firstIndex(where: { $0.remaining > 0 && $0.match(request) }) else { return nil }
            list[index].remaining -= 1
            return list[index].fault
        }
    }

    func open(_ request: HTTPRequest) async throws -> HTTPResponse {
        log.withLock { $0.append(request) }
        try Task.checkCancellation()
        let fault = takeFault(for: request)
        if case .transportError(let error)? = fault { throw error }
        guard let file = files.withLock({ $0[request.url.absoluteString] }) else {
            return HTTPResponse(head: HTTPResponseHead(statusCode: 404, headers: [:], url: request.url), body: FakeBody(data: Data()))
        }
        if case .status(let code, let headers)? = fault {
            return HTTPResponse(head: HTTPResponseHead(statusCode: code, headers: headers, url: request.url), body: FakeBody(data: Data()))
        }
        var headers: [String: String] = [:]
        if let etag = file.etag { headers["ETag"] = etag }
        if let lm = file.lastModified { headers["Last-Modified"] = lm }
        if let cd = file.contentDisposition { headers["Content-Disposition"] = cd }
        if let ct = file.contentType { headers["Content-Type"] = ct }
        let total = Int64(file.data.count)
        var ignoreRange = false
        if case .ignoreRange? = fault { ignoreRange = true }
        if let start = request.rangeStart, file.supportsRanges, !ignoreRange {
            if start >= total {
                headers["Content-Range"] = "bytes */\(total)"
                return HTTPResponse(head: HTTPResponseHead(statusCode: 416, headers: headers, url: request.url), body: FakeBody(data: Data()))
            }
            let last = min(total - 1, request.rangeEnd ?? (total - 1))
            headers["Content-Range"] = "bytes \(start)-\(last)/\(total)"
            headers["Content-Length"] = String(last - start + 1)
            let slice = file.data.subdata(in: Int(start)..<Int(last + 1))
            var drop: Int?
            if case .dropAfter(let bytes)? = fault { drop = bytes }
            let body = FakeBody(data: slice, chunkSize: file.chunkSize, chunkDelay: file.chunkDelay, dropAfter: drop, baseOffset: start, slow: slowFrom.current)
            return HTTPResponse(head: HTTPResponseHead(statusCode: 206, headers: headers, url: request.url), body: body)
        }
        if file.sendsLength { headers["Content-Length"] = String(total) }
        var drop: Int?
        if case .dropAfter(let bytes)? = fault { drop = bytes }
        let body = FakeBody(data: file.data, chunkSize: file.chunkSize, chunkDelay: file.chunkDelay, dropAfter: drop, baseOffset: 0, slow: slowFrom.current)
        return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: headers, url: request.url), body: body)
    }
}

final class FakeBody: HTTPBody, @unchecked Sendable {
    private let data: Data
    private let chunkSize: Int
    private let chunkDelay: Double
    private let dropAfter: Int?
    private let baseOffset: Int64
    private let slow: (offset: Int64, delay: Double)?
    private let position = Locked(0)
    private let cancelled = Locked(false)

    init(data: Data, chunkSize: Int = 64 * 1024, chunkDelay: Double = 0, dropAfter: Int? = nil, baseOffset: Int64 = 0, slow: (offset: Int64, delay: Double)? = nil) {
        self.data = data
        self.chunkSize = max(1, chunkSize)
        self.chunkDelay = chunkDelay
        self.dropAfter = dropAfter
        self.baseOffset = baseOffset
        self.slow = slow
    }

    func next() async throws -> Data? {
        if cancelled.current { throw CancellationError() }
        let start = position.current
        if let dropAfter, start >= dropAfter { throw TransportError.connectionLost }
        guard start < data.count else { return nil }
        var delay = chunkDelay
        if let slow, baseOffset + Int64(start) >= slow.offset { delay = max(delay, slow.delay) }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if cancelled.current { throw CancellationError() }
        var end = min(data.count, start + chunkSize)
        if let dropAfter { end = min(end, dropAfter) }
        position.withLock { $0 = end }
        return data.subdata(in: start..<end)
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}

enum TestData {
    /// Deterministic bytes so a misplaced piece is caught.
    static func bytes(_ count: Int, seed: UInt32 = 7) -> Data {
        var data = Data(count: count)
        var x = seed
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for i in 0..<count {
                x = x &* 1_103_515_245 &+ 12345
                raw[i] = UInt8(truncatingIfNeeded: x >> 16)
            }
        }
        return data
    }
}

/// A fresh temporary folder per test.
final class TempFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("LadleKitTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}
