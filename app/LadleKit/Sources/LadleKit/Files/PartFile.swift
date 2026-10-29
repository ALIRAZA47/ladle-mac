#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// The `.ladle-part` file. Connections write their pieces into it at their own offsets,
/// from several threads at once, with `pwrite`.
public final class PartFile: @unchecked Sendable {
    public let url: URL
    private let fd: Int32
    private let closed = Locked(false)

    /// Opens (creating if needed) the part file. With `truncate`, existing bytes are dropped.
    public init(url: URL, truncate: Bool = false) throws {
        self.url = url
        var flags = O_RDWR | O_CREAT
        if truncate { flags |= O_TRUNC }
        let descriptor = url.path.withCString { open($0, flags, 0o644) }
        guard descriptor >= 0 else { throw PartFile.error(POSIXFailure("open")) }
        fd = descriptor
    }

    deinit {
        close()
    }

    /// Reserves `size` bytes on disk and sets the file length. Fails early when the disk is full.
    public func preallocate(size: Int64) throws {
        guard size > 0 else { return }
        let current = try length()
        guard current < size else { return }
        #if canImport(Darwin)
        var store = fstore_t(
            fst_flags: UInt32(F_ALLOCATECONTIG | F_ALLOCATEALL),
            fst_posmode: F_PEOFPOSMODE,
            fst_offset: 0,
            fst_length: off_t(size - current),
            fst_bytesalloc: 0
        )
        if fcntl(fd, F_PREALLOCATE, &store) == -1 {
            store.fst_flags = UInt32(F_ALLOCATEALL)
            if fcntl(fd, F_PREALLOCATE, &store) == -1 {
                let failure = POSIXFailure("preallocate")
                if failure.isNoSpace { throw PartFile.error(failure) }
                // Some file systems can't preallocate; the length below is enough.
            }
        }
        #endif
        guard ftruncate(fd, off_t(size)) == 0 else { throw PartFile.error(POSIXFailure("ftruncate")) }
    }

    public func setLength(_ size: Int64) throws {
        guard ftruncate(fd, off_t(size)) == 0 else { throw PartFile.error(POSIXFailure("ftruncate")) }
    }

    public func length() throws -> Int64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw PartFile.error(POSIXFailure("fstat")) }
        return Int64(info.st_size)
    }

    /// Writes all of `data` at `offset`.
    public func write(_ data: Data, at offset: Int64) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let result = pwrite(fd, base + written, raw.count - written, off_t(offset + Int64(written)))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw PartFile.error(POSIXFailure("pwrite"))
                }
                written += result
            }
        }
    }

    /// Reads `count` bytes at `offset` (used by tests and checksum of part files).
    public func read(count: Int, at offset: Int64) throws -> Data {
        var data = Data(count: count)
        let got: Int = try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return 0 }
            var total = 0
            while total < count {
                let result = pread(fd, base + total, count - total, off_t(offset + Int64(total)))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw PartFile.error(POSIXFailure("pread"))
                }
                if result == 0 { break }
                total += result
            }
            return total
        }
        return data.prefix(got)
    }

    /// Flushes written pieces to disk, so saved offsets never claim more than is stored.
    public func sync() throws {
        guard fsync(fd) == 0 else { throw PartFile.error(POSIXFailure("fsync")) }
    }

    public func close() {
        let shouldClose = closed.withLock { (isClosed: inout Bool) -> Bool in
            if isClosed { return false }
            isClosed = true
            return true
        }
        if shouldClose {
            #if canImport(Darwin)
            _ = Darwin.close(fd)
            #elseif canImport(Glibc)
            _ = Glibc.close(fd)
            #elseif canImport(Musl)
            _ = Musl.close(fd)
            #endif
        }
    }

    static func error(_ failure: POSIXFailure) -> DownloadFailure {
        failure.isNoSpace ? DownloadFailure(.diskFull) : DownloadFailure(.writeFailed)
    }
}
