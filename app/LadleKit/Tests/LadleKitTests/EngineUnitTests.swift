import XCTest
@testable import LadleKit

/// A clock whose time only moves when the test says so.
final class ManualClock: LadleClock, @unchecked Sendable {
    private let state = Locked((date: Date(timeIntervalSince1970: 1_800_000_000), uptime: 1000.0))

    func now() -> Date { state.current.date }
    func uptime() -> Double { state.current.uptime }
    func sleep(seconds: Double) async throws {
        advance(seconds)
        await Task.yield()
    }

    func advance(_ seconds: Double) {
        state.withLock { s in
            s.uptime += seconds
            s.date = s.date.addingTimeInterval(seconds)
        }
    }

    func set(date: Date) {
        state.withLock { $0.date = date }
    }
}

final class RetryTests: XCTestCase {
    func testBackoffDoublesUpToSixteenSeconds() {
        let policy = RetryPolicy(limit: 10)
        let delays = (1...7).map { policy.delay(forAttempt: $0, random: 0.5) }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 16, 16])
    }

    func testJitterStaysWithinTwentyPercent() {
        let policy = RetryPolicy(limit: 3)
        XCTAssertEqual(policy.delay(forAttempt: 3, random: 0), 3.2, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 3, random: 1), 4.8, accuracy: 1e-9)
        for _ in 0..<100 {
            let d = policy.delay(forAttempt: 2)
            XCTAssertGreaterThanOrEqual(d, 1.6)
            XCTAssertLessThanOrEqual(d, 2.4)
        }
    }

    func testRetryLimits() {
        XCTAssertFalse(RetryPolicy(limit: 0).allowsRetry(afterFailures: 1))
        XCTAssertTrue(RetryPolicy(limit: 3).allowsRetry(afterFailures: 3))
        XCTAssertFalse(RetryPolicy(limit: 3).allowsRetry(afterFailures: 4))
    }

    func testClassifiesStatuses() {
        XCTAssertEqual(ResponseClass.classify(status: 206), .ok)
        XCTAssertEqual(ResponseClass.classify(status: 429), .slowDown)
        XCTAssertEqual(ResponseClass.classify(status: 503), .slowDown)
        XCTAssertEqual(ResponseClass.classify(status: 502), .retry)
        XCTAssertEqual(ResponseClass.classify(status: 416), .rangeNotSatisfiable)
        XCTAssertEqual(ResponseClass.classify(status: 404), .fatal(DownloadFailure(.notFound, httpStatus: 404)))
        XCTAssertEqual(ResponseClass.classify(status: 403), .fatal(DownloadFailure(.forbidden, httpStatus: 403)))
        XCTAssertEqual(ResponseClass.classify(status: 302), .fatal(DownloadFailure(.invalidResponse, httpStatus: 302)))
    }

    func testRetryAfterHeader() {
        let now = Date(timeIntervalSince1970: 1_700_000_000) // Tue, 14 Nov 2023 22:13:20 GMT
        XCTAssertEqual(RetryAfter.seconds(from: "120", now: now), 120)
        XCTAssertEqual(RetryAfter.seconds(from: "999999", now: now), 3600, "capped at an hour")
        XCTAssertEqual(RetryAfter.seconds(from: "Tue, 14 Nov 2023 22:14:20 GMT", now: now) ?? -1, 60, accuracy: 0.5)
        XCTAssertEqual(RetryAfter.seconds(from: "Tue, 14 Nov 2023 22:00:00 GMT", now: now), 0, "past dates mean now")
        XCTAssertNil(RetryAfter.seconds(from: "soon", now: now))
        XCTAssertNil(RetryAfter.seconds(from: nil, now: now))
    }

    func testContentRange() {
        XCTAssertEqual(ContentRange.parse("bytes 0-99/1234"), ContentRange(start: 0, end: 99, total: 1234))
        XCTAssertEqual(ContentRange.parse("bytes 100-199/*"), ContentRange(start: 100, end: 199, total: nil))
        XCTAssertEqual(ContentRange.parse("bytes */0"), ContentRange(start: nil, end: nil, total: 0))
        XCTAssertNil(ContentRange.parse("bytes 9-1/10"))
        XCTAssertNil(ContentRange.parse("items 0-1/2"))
    }

    func testValidators() {
        let saved = Validator(etag: "\"a\"", lastModified: "x", size: 10)
        XCTAssertTrue(saved.matches(Validator(etag: "\"a\"", lastModified: "y", size: 10)), "ETag wins over Last-Modified")
        XCTAssertFalse(saved.matches(Validator(etag: "\"b\"", lastModified: "x", size: 10)))
        XCTAssertFalse(saved.matches(Validator(etag: "\"a\"", lastModified: "x", size: 11)), "size always counts")
        XCTAssertTrue(Validator(lastModified: "x", size: 10).matches(Validator(etag: "\"new\"", lastModified: "x", size: 10)))
        XCTAssertFalse(Validator(lastModified: "x", size: 10).matches(Validator(lastModified: "y", size: 10)))
    }
}

final class ThrottleTests: XCTestCase {
    func testHalvesConnectionsAndHonorsRetryAfter() {
        let clock = ManualClock()
        let throttle = HostThrottle(clock: clock)
        XCTAssertEqual(throttle.allowedConnections(host: "a.org", wanted: 8), 8)
        XCTAssertEqual(throttle.pushedBack(host: "A.org", currentConnections: 8, retryAfter: 30), 4)
        XCTAssertEqual(throttle.allowedConnections(host: "a.org", wanted: 8), 4)
        XCTAssertEqual(throttle.waitTime(host: "a.org"), 30, accuracy: 1e-9)
        XCTAssertEqual(throttle.pushedBack(host: "a.org", currentConnections: 8, retryAfter: nil), 2)
        XCTAssertEqual(throttle.pushedBack(host: "a.org", currentConnections: 2, retryAfter: nil), 1)
        XCTAssertEqual(throttle.pushedBack(host: "a.org", currentConnections: 1, retryAfter: nil), 1, "never below one")
        XCTAssertEqual(throttle.allowedConnections(host: "other.org", wanted: 8), 8, "per host")
        clock.advance(31)
        XCTAssertEqual(throttle.waitTime(host: "a.org"), 0)
        clock.advance(HostThrottle.quietPeriod)
        XCTAssertEqual(throttle.allowedConnections(host: "a.org", wanted: 8), 8, "lifts after a quiet period")
    }

    func testTokenBucketLimitsTheRate() {
        let clock = ManualClock()
        let bucket = TokenBucket(bytesPerSecond: 1_000_000, clock: clock)
        XCTAssertEqual(bucket.limit, 1_000_000)
        var t = clock.uptime()
        // A full bucket allows a quarter second of burst.
        t += 1
        XCTAssertEqual(bucket.reserve(250_000, now: t), 0)
        // Then 100 kB more must wait 0.1 s.
        XCTAssertEqual(bucket.reserve(100_000, now: t), 0.1, accuracy: 1e-9)
        // Over a long run the average equals the limit.
        var waited = 0.0
        for _ in 0..<100 {
            let wait = bucket.reserve(50_000, now: t)
            waited += wait
            t += wait
        }
        XCTAssertEqual(waited, 5.0, accuracy: 0.15)
        bucket.setLimit(nil)
        XCTAssertNil(bucket.limit)
        XCTAssertEqual(bucket.reserve(10_000_000, now: t), 0)
    }

    func testSpeedMeter() {
        let meter = SpeedMeter(window: 3)
        // 100 kB every tenth of a second is 1 MB/s.
        for step in 0...25 { meter.record(100_000, at: 10 + Double(step) / 10) }
        XCTAssertEqual(meter.rate(at: 12.5), 1_000_000, accuracy: 50_000)
        XCTAssertEqual(meter.rate(at: 30), 0)
    }
}

final class PieceTableTests: XCTestCase {
    let mib: Int64 = 1 << 20

    func testInitialSplit() {
        let pieces = PieceTable.initialPieces(total: 100 * mib, connections: 8, minPiece: mib)
        XCTAssertEqual(pieces.count, 8)
        XCTAssertEqual(pieces.first?.start, 0)
        XCTAssertEqual(pieces.last?.end, 100 * mib)
        for (a, b) in zip(pieces, pieces.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        XCTAssertEqual(PieceTable.initialPieces(total: 3 * mib, connections: 8, minPiece: mib).count, 3, "minimum piece 1 MiB")
        XCTAssertEqual(PieceTable.initialPieces(total: 1000, connections: 8, minPiece: mib).count, 1)
        XCTAssertEqual(PieceTable.initialPieces(total: 0, connections: 8, minPiece: mib), [Piece(start: 0, end: 0)])
    }

    func testClaimsUnownedPiecesFirst() {
        let table = PieceTable(pieces: PieceTable.initialPieces(total: 8 * mib, connections: 4, minPiece: mib), total: 8 * mib, minPiece: mib)
        XCTAssertEqual(table.claim(containing: 0, worker: 0)?.position, 0)
        XCTAssertEqual(table.claimNext(worker: 1)?.position, 2 * mib)
        XCTAssertEqual(table.claimNext(worker: 2)?.position, 4 * mib)
        XCTAssertEqual(table.claimNext(worker: 3)?.position, 6 * mib)
        XCTAssertEqual(table.activeCount, 4)
    }

    func testFinishedConnectionTakesSecondHalfOfLargestPiece() {
        let table = PieceTable(pieces: PieceTable.initialPieces(total: 8 * mib, connections: 2, minPiece: mib), total: 8 * mib, minPiece: mib)
        let a = table.claimNext(worker: 0)!
        let b = table.claimNext(worker: 1)!
        // Worker 0 finishes its 4 MiB piece; worker 1 has written 1 MiB of its piece.
        let slotA = table.reserve(id: a.id, worker: 0, count: Int(4 * mib))!
        XCTAssertEqual(slotA.allowed, Int(4 * mib))
        XCTAssertTrue(table.commit(id: a.id, worker: 0, bytes: slotA.allowed))
        table.release(id: a.id, worker: 0, failed: false)
        let slotB = table.reserve(id: b.id, worker: 1, count: Int(mib))!
        table.commit(id: b.id, worker: 1, bytes: slotB.allowed)
        // 3 MiB remain in worker 1's piece: worker 0 takes the second half, from 5.5 MiB.
        let split = table.claimNext(worker: 0)!
        XCTAssertEqual(split.position, 4 * mib + mib + (3 * mib) / 2)
        XCTAssertEqual(split.end, 8 * mib)
        XCTAssertEqual(table.end(of: b.id), split.position, "the old piece now ends where the new one starts")
        // Worker 1 can only write up to its new end.
        let capped = table.reserve(id: b.id, worker: 1, count: Int(4 * mib))!
        XCTAssertEqual(Int64(capped.allowed), split.position - (5 * mib))
    }

    func testDoesNotSplitBelowTwoMinimumPieces() {
        let table = PieceTable(pieces: [Piece(start: 0, end: 3 * mib - 1)], total: 3 * mib - 1, minPiece: mib)
        let a = table.claimNext(worker: 0)!
        let slot = table.reserve(id: a.id, worker: 0, count: Int(mib))!
        table.commit(id: a.id, worker: 0, bytes: slot.allowed)
        XCTAssertNil(table.claimNext(worker: 1), "1.99 MiB left can't make two 1 MiB pieces")
    }

    func testInflightBytesAreNotStolen() {
        let table = PieceTable(pieces: [Piece(start: 0, end: 4 * mib)], total: 4 * mib, minPiece: mib)
        let a = table.claimNext(worker: 0)!
        _ = table.reserve(id: a.id, worker: 0, count: Int(mib))   // being written right now
        let split = table.claimNext(worker: 1)!
        XCTAssertEqual(split.position, mib + (3 * mib) / 2, "the split point is past the in-flight write")
    }

    func testFailuresAndOwnership() {
        let table = PieceTable(pieces: [Piece(start: 0, end: 10)], total: 10, minPiece: 1)
        let a = table.claimNext(worker: 0)!
        XCTAssertNil(table.reserve(id: a.id, worker: 5, count: 1), "only the owner writes")
        XCTAssertEqual(table.release(id: a.id, worker: 0, failed: true), 1)
        let again = table.claimNext(worker: 1)!
        XCTAssertEqual(table.release(id: again.id, worker: 1, failed: true), 2)
        let third = table.claimNext(worker: 1)!
        let slot = table.reserve(id: third.id, worker: 1, count: 3)!
        table.commit(id: third.id, worker: 1, bytes: slot.allowed)
        XCTAssertEqual(table.release(id: third.id, worker: 1, failed: true), 1, "progress resets the failure count")
    }

    func testOpenEndedPieceForUnknownSize() {
        let table = PieceTable(pieces: [Piece(start: 0, end: Int64.max)], total: nil)
        let a = table.claimNext(worker: 0)!
        XCTAssertNil(table.claimNext(worker: 1), "no splitting without a size")
        let slot = table.reserve(id: a.id, worker: 0, count: 500)!
        table.commit(id: a.id, worker: 0, bytes: slot.allowed)
        XCTAssertFalse(table.isComplete)
        table.finishOpenEnded(id: a.id, worker: 0)
        XCTAssertTrue(table.isComplete)
        XCTAssertEqual(table.total, 500)
    }

    func testCompactsFinishedNeighbours() {
        let pieces = [Piece(start: 0, end: 10, received: 10), Piece(start: 10, end: 20, received: 10), Piece(start: 20, end: 30, received: 5), Piece(start: 30, end: 40, received: 10)]
        XCTAssertEqual(PieceTable.compact(pieces), [Piece(start: 0, end: 20, received: 20), Piece(start: 20, end: 30, received: 5), Piece(start: 30, end: 40, received: 10)])
    }

    func testSlotFractions() {
        let pieces = [Piece(start: 0, end: 50, received: 25), Piece(start: 50, end: 100, received: 50)]
        XCTAssertEqual(PieceTable.slotFractions(pieces: pieces, total: 100, slots: 2), [0.5, 1])
        XCTAssertEqual(PieceTable.slotFractions(pieces: pieces, total: 100, slots: 4), [1, 0, 1, 1])
        XCTAssertEqual(PieceTable.slotFractions(pieces: [Piece(start: 0, end: 10, received: 10)], total: 10, slots: 3), [1, 1, 1])
        XCTAssertEqual(PieceTable.slotFractions(pieces: [], total: nil, slots: 2), [0, 0])
        let split = [Piece(start: 0, end: 7, received: 7), Piece(start: 7, end: 10, received: 0)]
        let fractions = PieceTable.slotFractions(pieces: split, total: 10, slots: 3)
        XCTAssertEqual(fractions[0], 1)
        XCTAssertEqual(fractions[1], 1)
        XCTAssertEqual(fractions[2], 0.25, accuracy: 1e-9)
    }
}
