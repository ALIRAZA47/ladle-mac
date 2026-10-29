import Foundation

/// What a downloader needs to know to start or resume one file.
public struct FileJob: Sendable {
    public var url: URL
    public var cookies: String?
    public var referrer: URL?
    public var userAgent: String?
    /// Where the part file is (or would be, under the current name).
    public var partURL: URL
    /// Saved progress. Empty for a fresh start.
    public var pieces: [Piece]
    public var total: Int64?
    public var validator: Validator?
    public var resumable: Bool?
    public var connections: Int
    public var retryLimit: Int
    public var minPiece: Int64

    public init(
        url: URL,
        partURL: URL,
        cookies: String? = nil,
        referrer: URL? = nil,
        userAgent: String? = nil,
        pieces: [Piece] = [],
        total: Int64? = nil,
        validator: Validator? = nil,
        resumable: Bool? = nil,
        connections: Int = 8,
        retryLimit: Int = 3,
        minPiece: Int64 = PieceTable.defaultMinPiece
    ) {
        self.url = url
        self.partURL = partURL
        self.cookies = cookies
        self.referrer = referrer
        self.userAgent = userAgent
        self.pieces = pieces
        self.total = total
        self.validator = validator
        self.resumable = resumable
        self.connections = max(1, connections)
        self.retryLimit = retryLimit
        self.minPiece = minPiece
    }

    var hasProgress: Bool { pieces.contains { $0.received > 0 } }
}

/// What the first response told us. The coordinator uses it to settle the file name.
public struct ProbeInfo: Sendable, Equatable {
    public var total: Int64?
    public var resumable: Bool
    public var validator: Validator
    public var suggestedName: String?
    public var mimeType: String?
    public var finalURL: URL
    public var isFreshStart: Bool
}

public enum DownloadOutcome: Sendable, Equatable {
    case completed(total: Int64)
    case failed(DownloadFailure)
    case cancelled
}

/// Live numbers for the interface.
public struct TransferProgress: Sendable, Equatable {
    public var received: Int64
    public var total: Int64?
    public var pieces: [Piece]
    public var activeConnections: Int
    public var speed: Double
    public var resumable: Bool?
    public var validator: Validator?
}

/// Downloads one file over several connections into its `.ladle-part` file.
public final class FileDownloader: @unchecked Sendable {
    public typealias Prepare = @Sendable (ProbeInfo) async throws -> URL

    private let job: FileJob
    private let transport: HTTPTransport
    private let limiter: TokenBucket
    private let throttle: HostThrottle
    private let clock: LadleClock
    private let prepare: Prepare
    private let meter = SpeedMeter()
    private let policy: RetryPolicy
    private let host: String

    private struct State {
        var table: PieceTable?
        var part: PartFile?
        var resumable: Bool?
        var validator: Validator?
        var total: Int64?
        /// Most failures in a row of any one piece, so "Tried 4 times" is honest.
        var mostFailures = 0
        var rangesSupported = false
        /// Synced and closed: the table is final.
        var closed = false
    }

    private let state = Locked(State())

    public init(
        job: FileJob,
        transport: HTTPTransport,
        limiter: TokenBucket,
        throttle: HostThrottle,
        clock: LadleClock = SystemClock(),
        prepare: @escaping Prepare
    ) {
        self.job = job
        self.transport = transport
        self.limiter = limiter
        self.throttle = throttle
        self.clock = clock
        self.prepare = prepare
        self.policy = RetryPolicy(limit: job.retryLimit)
        self.host = job.url.host ?? ""
        state.withLock { s in
            s.resumable = job.resumable
            s.validator = job.validator
            s.total = job.total
        }
    }

    /// Tries of the piece that failed most (first try plus retries).
    public var attempts: Int { state.current.mostFailures }

    public func progress() -> TransferProgress {
        let s = state.current
        let pieces = s.table?.snapshot() ?? job.pieces
        return TransferProgress(
            received: s.table?.receivedBytes ?? job.pieces.reduce(0) { $0 + $1.received },
            total: s.table?.total ?? s.total,
            pieces: pieces,
            activeConnections: s.table?.activeCount ?? 0,
            speed: meter.rate(at: clock.uptime()),
            resumable: s.resumable,
            validator: s.validator
        )
    }

    /// Pieces as they are on disk right now (flushes first). Safe to save.
    public func checkpoint() -> [Piece]? {
        let s = state.current
        guard let table = s.table else { return nil }
        let pieces = table.snapshot()
        if s.closed { return pieces }
        do { try s.part?.sync() } catch { return nil }
        return pieces
    }

    private func closePart() {
        let part = state.withLock { s -> PartFile? in
            s.closed = true
            return s.part
        }
        try? part?.sync()
        part?.close()
    }

    public func run() async -> DownloadOutcome {
        do {
            let total = try await runTransfer()
            if let part = state.current.part {
                do { try part.sync() } catch { closePart(); return .failed(DownloadFailure(.writeFailed)) }
            }
            closePart()
            return .completed(total: total)
        } catch {
            closePart()
            if error is CancellationError || Task.isCancelled { return .cancelled }
            if let failure = error as? DownloadFailure { return .failed(failure) }
            if let transportError = error as? TransportError { return .failed(transportError.failure) }
            return .failed(DownloadFailure(.network))
        }
    }

    // MARK: - Probe

    private func request(start: Int64?, end: Int64?, slot: Int) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let ua = job.userAgent, !ua.isEmpty { headers["User-Agent"] = ua }
        return HTTPRequest(
            url: job.url,
            rangeStart: start,
            rangeEnd: end,
            cookies: job.cookies,
            referrer: job.referrer,
            headers: headers,
            connectionSlot: slot
        )
    }

    /// Waits before the next try, or throws `failure` when the retry budget is spent.
    private func backOff(failures: Int, failure: DownloadFailure, retryAfter: Double? = nil) async throws {
        state.withLock { $0.mostFailures = max($0.mostFailures, failures) }
        guard failure.isRetryable || retryAfter != nil, policy.allowsRetry(afterFailures: failures) else { throw failure }
        let delay = max(policy.delay(forAttempt: failures), retryAfter ?? 0)
        try await clock.sleep(seconds: delay)
    }

    private func runTransfer() async throws -> Int64 {
        var resuming = job.resumable == true && job.hasProgress && job.total != nil
        if job.resumable == false && job.hasProgress {
            throw DownloadFailure(.cannotResume)
        }
        if resuming && !FileManager.default.fileExists(atPath: job.partURL.path) {
            // The part file is gone, so there is nothing to keep.
            resuming = false
        }
        let startAt: Int64 = resuming ? (job.pieces.filter { !$0.isComplete }.map(\.position).min() ?? 0) : 0
        if resuming && job.pieces.allSatisfy({ $0.isComplete }), let total = job.total {
            let part = try PartFile(url: job.partURL)
            let table = PieceTable(pieces: job.pieces, total: total, minPiece: job.minPiece)
            state.withLock { s in
                s.part = part
                s.table = table
            }
            return total
        }

        var failures = 0
        while true {
            try Task.checkCancellation()
            let wait = throttle.waitTime(host: host)
            if wait > 0 { try await clock.sleep(seconds: wait) }
            let response: HTTPResponse
            do {
                response = try await transport.open(request(start: startAt, end: nil, slot: 0))
            } catch let error as CancellationError {
                throw error
            } catch {
                failures += 1
                try await backOff(failures: failures, failure: FileDownloader.failure(from: error))
                continue
            }
            let head = response.head
            switch ResponseClass.classify(status: head.statusCode) {
            case .ok:
                return try await begin(with: response, resuming: resuming, startAt: startAt)
            case .slowDown:
                response.body.cancel()
                failures += 1
                let after = RetryAfter.seconds(from: head.header("retry-after"), now: clock.now())
                throttle.pushedBack(host: host, currentConnections: job.connections, retryAfter: after)
                try await backOff(failures: failures, failure: DownloadFailure(.serverError, httpStatus: head.statusCode), retryAfter: after ?? 1)
            case .retry:
                response.body.cancel()
                failures += 1
                try await backOff(failures: failures, failure: DownloadFailure(.serverError, httpStatus: head.statusCode))
            case .rangeNotSatisfiable:
                response.body.cancel()
                if !resuming, head.contentRange?.total == 0 {
                    return try await beginEmpty(head: head)
                }
                throw DownloadFailure(resuming ? .changedOnServer : .invalidResponse, httpStatus: 416)
            case .fatal(let failure):
                response.body.cancel()
                throw failure
            }
        }
    }

    private func beginEmpty(head: HTTPResponseHead) async throws -> Int64 {
        let info = ProbeInfo(
            total: 0,
            resumable: false,
            validator: Validator(etag: head.header("etag"), lastModified: head.header("last-modified"), size: 0),
            suggestedName: head.header("content-disposition").flatMap(FileNaming.nameFromContentDisposition),
            mimeType: head.header("content-type"),
            finalURL: head.url,
            isFreshStart: true
        )
        let partURL = try await prepare(info)
        let part = try PartFile(url: partURL, truncate: true)
        state.withLock { s in
            s.part = part
            s.total = 0
            s.table = PieceTable(pieces: [Piece(start: 0, end: 0)], total: 0)
        }
        return 0
    }

    private func begin(with response: HTTPResponse, resuming: Bool, startAt: Int64) async throws -> Int64 {
        let head = response.head
        var resuming = resuming
        let ranged: Bool
        var total: Int64?
        if head.statusCode == 206 {
            guard let range = head.contentRange, range.start == startAt else {
                response.body.cancel()
                throw DownloadFailure(.invalidResponse, httpStatus: 206)
            }
            ranged = true
            total = range.total
        } else {
            ranged = false
            total = head.contentLength
            if resuming {
                if startAt > 0 {
                    response.body.cancel()
                    throw DownloadFailure(.cannotResume)
                }
                resuming = false
            }
        }
        let validator = Validator(etag: head.header("etag"), lastModified: head.header("last-modified"), size: total)
        if resuming {
            guard total == job.total, validator.matches(job.validator ?? Validator(size: job.total)) else {
                response.body.cancel()
                throw DownloadFailure(.changedOnServer)
            }
        }
        // Split only when the server gives ranges and the size.
        let splittable = ranged && total != nil
        let info = ProbeInfo(
            total: total,
            resumable: ranged,
            validator: validator,
            suggestedName: head.header("content-disposition").flatMap(FileNaming.nameFromContentDisposition),
            mimeType: head.header("content-type"),
            finalURL: head.url,
            isFreshStart: !resuming
        )
        let partURL: URL
        do {
            partURL = try await prepare(info)
        } catch {
            response.body.cancel()
            throw error
        }
        let part: PartFile
        let pieces: [Piece]
        do {
            if resuming {
                part = try PartFile(url: partURL)
                if let total, try part.length() < total { try part.preallocate(size: total) }
                pieces = job.pieces
            } else {
                part = try PartFile(url: partURL, truncate: true)
                if let total {
                    try part.preallocate(size: total)
                    pieces = splittable ? PieceTable.initialPieces(total: total, connections: job.connections, minPiece: job.minPiece) : [Piece(start: 0, end: total)]
                } else {
                    pieces = [Piece(start: 0, end: Int64.max)]
                }
            }
        } catch {
            response.body.cancel()
            throw error
        }
        let table = PieceTable(pieces: pieces, total: total, minPiece: job.minPiece)
        state.withLock { s in
            s.part = part
            s.table = table
            s.resumable = ranged
            s.validator = validator
            s.total = total
            s.rangesSupported = splittable
        }
        guard let firstClaim = table.claim(containing: startAt, worker: 0) else {
            response.body.cancel()
            throw DownloadFailure(.invalidResponse)
        }
        let workerCount = splittable ? job.connections : 1
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.worker(0, table: table, part: part, splittable: splittable, ranged: ranged, total: total, pending: (firstClaim, response))
            }
            if workerCount > 1 {
                for index in 1..<workerCount {
                    group.addTask {
                        try await self.worker(index, table: table, part: part, splittable: splittable, ranged: ranged, total: total, pending: nil)
                    }
                }
            }
            for try await _ in group {}
        }
        guard table.isComplete else { throw DownloadFailure(.invalidResponse) }
        return table.total ?? table.receivedBytes
    }

    // MARK: - Workers

    private func worker(
        _ index: Int,
        table: PieceTable,
        part: PartFile,
        splittable: Bool,
        ranged: Bool,
        total: Int64?,
        pending initial: (PieceTable.Claim, HTTPResponse)?
    ) async throws {
        var pending = initial
        while !table.isComplete {
            try Task.checkCancellation()
            let cap = throttle.allowedConnections(host: host, wanted: splittable ? job.connections : 1)
            if index >= cap {
                if let (claim, response) = pending {
                    response.body.cancel()
                    table.release(id: claim.id, worker: index, failed: false)
                    pending = nil
                }
                try await clock.sleep(seconds: 1)
                continue
            }
            let claim: PieceTable.Claim
            let response: HTTPResponse
            if let current = pending {
                claim = current.0
                response = current.1
                pending = nil
            } else {
                guard let next = table.claimNext(worker: index, allowSplit: splittable) else {
                    try await clock.sleep(seconds: 0.25)
                    continue
                }
                claim = next
                do {
                    response = try await openPiece(claim, worker: index, ranged: ranged, total: total, table: table)
                } catch let error as CancellationError {
                    table.release(id: claim.id, worker: index, failed: false)
                    throw error
                } catch let skip as PieceSkip {
                    let failures = table.release(id: claim.id, worker: index, failed: true)
                    try await backOff(failures: failures, failure: skip.failure, retryAfter: skip.retryAfter)
                    continue
                } catch {
                    let failures = table.release(id: claim.id, worker: index, failed: true)
                    try await backOff(failures: failures, failure: FileDownloader.failure(from: error))
                    continue
                }
            }
            do {
                try await stream(response, claim: claim, worker: index, table: table, part: part, total: total)
                table.release(id: claim.id, worker: index, failed: false)
            } catch let error as CancellationError {
                response.body.cancel()
                table.release(id: claim.id, worker: index, failed: false)
                throw error
            } catch let failure as DownloadFailure where !failure.isRetryable {
                response.body.cancel()
                throw failure
            } catch {
                response.body.cancel()
                let failures = table.release(id: claim.id, worker: index, failed: true)
                try await backOff(failures: failures, failure: FileDownloader.failure(from: error))
            }
        }
    }

    /// A response that means "try this piece again later".
    private struct PieceSkip: Error {
        var failure: DownloadFailure
        var retryAfter: Double?
    }

    private func openPiece(_ claim: PieceTable.Claim, worker: Int, ranged: Bool, total: Int64?, table: PieceTable) async throws -> HTTPResponse {
        let wait = throttle.waitTime(host: host)
        if wait > 0 { try await clock.sleep(seconds: wait) }
        let response: HTTPResponse
        if ranged {
            let end = table.end(of: claim.id) ?? claim.end
            let lastByte: Int64? = total == nil ? nil : end - 1
            response = try await transport.open(request(start: claim.position, end: lastByte, slot: worker))
        } else {
            // No ranges: the only way to retry is from the start.
            table.resetForRestart(id: claim.id, worker: worker)
            response = try await transport.open(request(start: nil, end: nil, slot: worker))
        }
        let head = response.head
        switch ResponseClass.classify(status: head.statusCode) {
        case .ok:
            break
        case .slowDown:
            response.body.cancel()
            let after = RetryAfter.seconds(from: head.header("retry-after"), now: clock.now())
            throttle.pushedBack(host: host, currentConnections: max(1, table.activeCount), retryAfter: after)
            throw PieceSkip(failure: DownloadFailure(.serverError, httpStatus: head.statusCode), retryAfter: after ?? 1)
        case .retry:
            response.body.cancel()
            throw PieceSkip(failure: DownloadFailure(.serverError, httpStatus: head.statusCode), retryAfter: nil)
        case .rangeNotSatisfiable:
            response.body.cancel()
            throw DownloadFailure(.changedOnServer, httpStatus: 416)
        case .fatal(let failure):
            response.body.cancel()
            throw failure
        }
        guard ranged else {
            if head.statusCode != 200 {
                response.body.cancel()
                throw PieceSkip(failure: DownloadFailure(.invalidResponse, httpStatus: head.statusCode), retryAfter: nil)
            }
            if let expected = total, let length = head.contentLength, length != expected {
                response.body.cancel()
                throw DownloadFailure(.changedOnServer)
            }
            return response
        }
        if head.statusCode == 200 {
            // The server ignored the range on this connection, often a sign of too many connections.
            response.body.cancel()
            throttle.pushedBack(host: host, currentConnections: max(1, table.activeCount), retryAfter: nil)
            throw PieceSkip(failure: DownloadFailure(.serverError, httpStatus: 200), retryAfter: 1)
        }
        guard let range = head.contentRange, range.start == claim.position else {
            response.body.cancel()
            throw PieceSkip(failure: DownloadFailure(.invalidResponse, httpStatus: 206), retryAfter: nil)
        }
        if let total, let reported = range.total, reported != total {
            response.body.cancel()
            throw DownloadFailure(.changedOnServer)
        }
        if let expected = state.current.validator?.etag, let etag = head.header("etag"), etag != expected {
            response.body.cancel()
            throw DownloadFailure(.changedOnServer)
        }
        return response
    }

    private func stream(_ response: HTTPResponse, claim: PieceTable.Claim, worker: Int, table: PieceTable, part: PartFile, total: Int64?) async throws {
        while let chunk = try await response.body.next() {
            try await limiter.consume(chunk.count)
            guard let slot = table.reserve(id: claim.id, worker: worker, count: chunk.count) else {
                response.body.cancel()
                return
            }
            if slot.allowed > 0 {
                do {
                    try part.write(slot.allowed == chunk.count ? chunk : chunk.prefix(slot.allowed), at: slot.offset)
                } catch {
                    table.commit(id: claim.id, worker: worker, bytes: 0)
                    throw error
                }
            }
            let done = table.commit(id: claim.id, worker: worker, bytes: slot.allowed)
            meter.record(slot.allowed, at: clock.uptime())
            if done || slot.allowed < chunk.count {
                // Reached the piece's end (it may have shrunk when another connection took half).
                response.body.cancel()
                return
            }
        }
        if total == nil {
            table.finishOpenEnded(id: claim.id, worker: worker)
            state.withLock { $0.total = table.total }
            return
        }
        if table.isOwned(claim.id, by: worker) && !table.pieceIsComplete(claim.id) {
            // The server closed the connection before the piece was done.
            throw TransportError.connectionLost
        }
    }

    static func failure(from error: Error) -> DownloadFailure {
        if let failure = error as? DownloadFailure { return failure }
        if let transport = error as? TransportError { return transport.failure }
        return DownloadFailure(.network)
    }
}
