import Foundation

/// A value guarded by a lock. Used where state is touched from URLSession delegate
/// queues and worker tasks at the same time.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
