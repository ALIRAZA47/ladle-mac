import Foundation

/// Which connection is filling which byte range. Safe to use from many workers at once.
///
/// Dynamic splitting: a connection that runs out of work takes over the second half of the
/// largest piece still being filled, as long as both halves stay at least `minPiece` long.
public final class PieceTable: @unchecked Sendable {
    public static let defaultMinPiece: Int64 = 1 << 20

    /// Work handed to a worker: fill `[position, end)` of piece `id`. `end` can shrink later.
    public struct Claim: Equatable, Sendable {
        public var id: Int
        public var position: Int64
        public var end: Int64
    }

    struct Entry {
        var id: Int
        var piece: Piece
        var owner: Int?
        /// Bytes reserved by the owner for a write that hasn't been committed yet.
        var inflight: Int64
        var failures: Int
    }

    private let lock = NSLock()
    private var entries: [Entry]
    private var nextID: Int
    public let minPiece: Int64
    private var knownTotal: Int64?

    /// nil when the server didn't say how big the file is (one open-ended piece).
    public var total: Int64? {
        withLock { knownTotal }
    }

    public init(pieces: [Piece], total: Int64?, minPiece: Int64 = PieceTable.defaultMinPiece) {
        self.knownTotal = total
        self.minPiece = max(1, minPiece)
        let sorted = pieces.sorted { $0.start < $1.start }
        entries = sorted.enumerated().map { index, piece in
            Entry(id: index, piece: piece, owner: nil, inflight: 0, failures: 0)
        }
        nextID = sorted.count
    }

    /// Splits a file of `total` bytes into up to `connections` equal pieces of at least `minPiece`.
    public static func initialPieces(total: Int64, connections: Int, minPiece: Int64 = defaultMinPiece) -> [Piece] {
        guard total > 0 else { return [Piece(start: 0, end: 0)] }
        let maxByMin = max(1, Int(total / max(1, minPiece)))
        let count = max(1, min(connections, maxByMin))
        let size = total / Int64(count)
        var pieces: [Piece] = []
        var start: Int64 = 0
        for index in 0..<count {
            let end = index == count - 1 ? total : start + size
            pieces.append(Piece(start: start, end: end))
            start = end
        }
        return pieces
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func entryIndex(_ id: Int) -> Int? {
        entries.firstIndex(where: { $0.id == id })
    }

    private func effectivePosition(_ entry: Entry) -> Int64 {
        entry.piece.start + entry.piece.received + entry.inflight
    }

    /// Claims the unfinished, unowned piece that contains `position` (the probe connection's start).
    public func claim(containing position: Int64, worker: Int) -> Claim? {
        withLock {
            guard let index = entries.firstIndex(where: { e in
                e.owner == nil && !e.piece.isComplete && e.piece.position <= position && position < e.piece.end
            }) else { return nil }
            guard entries[index].piece.position == position else { return nil }
            entries[index].owner = worker
            let e = entries[index]
            return Claim(id: e.id, position: e.piece.position, end: e.piece.end)
        }
    }

    /// The next job for `worker`: an unowned unfinished piece, else half of the largest one in progress.
    public func claimNext(worker: Int, allowSplit: Bool = true) -> Claim? {
        withLock {
            if let index = entries.firstIndex(where: { $0.owner == nil && !$0.piece.isComplete }) {
                entries[index].owner = worker
                let e = entries[index]
                return Claim(id: e.id, position: e.piece.position, end: e.piece.end)
            }
            guard allowSplit, knownTotal != nil else { return nil }
            var best: Int?
            var bestRemaining: Int64 = 0
            for (index, e) in entries.enumerated() where e.owner != nil && !e.piece.isComplete {
                let remaining = e.piece.end - effectivePosition(e)
                if remaining > bestRemaining {
                    bestRemaining = remaining
                    best = index
                }
            }
            guard let index = best, bestRemaining >= 2 * minPiece else { return nil }
            let mid = effectivePosition(entries[index]) + bestRemaining / 2
            let oldEnd = entries[index].piece.end
            entries[index].piece.end = mid
            let id = nextID
            nextID += 1
            entries.insert(Entry(id: id, piece: Piece(start: mid, end: oldEnd), owner: worker, inflight: 0, failures: 0), at: index + 1)
            return Claim(id: id, position: mid, end: oldEnd)
        }
    }

    /// Reserves room to write up to `count` bytes. Returns the file offset and how many bytes fit
    /// before the piece's current end, or nil when the worker no longer owns the piece.
    public func reserve(id: Int, worker: Int, count: Int) -> (offset: Int64, allowed: Int)? {
        withLock {
            guard let index = entryIndex(id), entries[index].owner == worker else { return nil }
            let e = entries[index]
            let offset = e.piece.start + e.piece.received
            let room = max(0, e.piece.end - offset)
            let allowed = Int(min(Int64(count), room))
            entries[index].inflight = Int64(allowed)
            return (offset, allowed)
        }
    }

    /// Records bytes written. Returns true when the piece is now complete.
    @discardableResult
    public func commit(id: Int, worker: Int, bytes: Int) -> Bool {
        withLock {
            guard let index = entryIndex(id), entries[index].owner == worker else { return true }
            entries[index].piece.received += Int64(bytes)
            entries[index].inflight = 0
            if bytes > 0 { entries[index].failures = 0 }
            return entries[index].piece.isComplete
        }
    }

    /// The piece's current end (it shrinks when another connection takes half).
    public func end(of id: Int) -> Int64? {
        withLock { entryIndex(id).map { entries[$0].piece.end } }
    }

    public func pieceIsComplete(_ id: Int) -> Bool {
        withLock { entryIndex(id).map { entries[$0].piece.isComplete } ?? true }
    }

    /// Without range support a retry starts the file again, so the piece forgets its progress.
    public func resetForRestart(id: Int, worker: Int) {
        withLock {
            guard let index = entryIndex(id), entries[index].owner == worker else { return }
            entries[index].piece.received = 0
            entries[index].inflight = 0
        }
    }

    public func isOwned(_ id: Int, by worker: Int) -> Bool {
        withLock { entryIndex(id).map { entries[$0].owner == worker } ?? false }
    }

    /// Gives a piece back. Returns how many times in a row it has failed.
    @discardableResult
    public func release(id: Int, worker: Int, failed: Bool) -> Int {
        withLock {
            guard let index = entryIndex(id), entries[index].owner == worker else { return 0 }
            entries[index].owner = nil
            entries[index].inflight = 0
            if failed { entries[index].failures += 1 }
            return entries[index].failures
        }
    }

    /// For a file of unknown size: the stream ended, so the piece ends here.
    public func finishOpenEnded(id: Int, worker: Int) {
        withLock {
            guard let index = entryIndex(id), entries[index].owner == worker else { return }
            entries[index].piece.end = entries[index].piece.start + entries[index].piece.received
            knownTotal = entries[index].piece.end
        }
    }

    public var isComplete: Bool {
        withLock { entries.allSatisfy { $0.piece.isComplete } }
    }

    public var receivedBytes: Int64 {
        withLock { entries.reduce(0) { $0 + $1.piece.received } }
    }

    /// Pieces being filled right now.
    public var activeCount: Int {
        withLock { entries.filter { $0.owner != nil && !$0.piece.isComplete }.count }
    }

    /// Current pieces, sorted, with neighbouring finished pieces merged.
    public func snapshot() -> [Piece] {
        let pieces = withLock { entries.map { $0.piece } }
        return PieceTable.compact(pieces)
    }

    public static func compact(_ pieces: [Piece]) -> [Piece] {
        var result: [Piece] = []
        for piece in pieces.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.isComplete, piece.isComplete, last.end == piece.start {
                result[result.count - 1] = Piece(start: last.start, end: piece.end, received: last.length + piece.length)
            } else {
                result.append(piece)
            }
        }
        return result
    }

    /// How full each of `slots` equal parts of the file is: one bar segment or ring arc per connection.
    public static func slotFractions(pieces: [Piece], total: Int64?, slots: Int) -> [Double] {
        let count = max(1, slots)
        guard let total, total > 0 else {
            return [Double](repeating: 0, count: count)
        }
        let n = Int64(count)
        func boundary(_ k: Int64) -> Int64 { total * k / n }
        func slot(of position: Int64) -> Int64 {
            var k = min(n - 1, max(0, position * n / total))
            while k < n - 1 && boundary(k + 1) <= position { k += 1 }
            while k > 0 && boundary(k) > position { k -= 1 }
            return k
        }
        var filled = [Int64](repeating: 0, count: count)
        for piece in pieces where piece.received > 0 {
            var a = max(0, piece.start)
            let b = min(total, piece.start + min(piece.received, piece.length))
            while a < b {
                let k = slot(of: a)
                let upTo = min(b, boundary(k + 1))
                filled[Int(k)] += upTo - a
                a = upTo
            }
        }
        return (0..<count).map { k in
            let length = boundary(Int64(k) + 1) - boundary(Int64(k))
            guard length > 0 else { return 1 }
            return min(1, Double(filled[k]) / Double(length))
        }
    }
}
