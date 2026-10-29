#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// The C `errno` for the calling thread, with a readable message.
struct POSIXFailure: Error, CustomStringConvertible {
    let code: Int32
    let operation: String

    init(_ operation: String, code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    var isNoSpace: Bool { code == ENOSPC || code == EDQUOT }

    var description: String {
        "\(operation) failed: \(String(cString: strerror(code))) (\(code))"
    }
}
