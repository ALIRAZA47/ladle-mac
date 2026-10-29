import Foundation

/// Streaming MD5 (RFC 1321) in plain Swift. Only for checking published MD5 sums, not for security.
public struct PortableMD5: Sendable {
    private var state: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let k: [UInt32] = (0..<64).map { i in
        UInt32(truncatingIfNeeded: Int64(abs(sin(Double(i + 1))) * 4_294_967_296.0))
    }

    public init() {}

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            update(bytes: raw)
        }
    }

    public mutating func update(bytes raw: UnsafeRawBufferPointer) {
        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        length &+= UInt64(raw.count)
        var offset = 0
        let count = raw.count
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, count)
            buffer.append(contentsOf: UnsafeBufferPointer(start: base, count: take))
            offset = take
            if buffer.count == 64 {
                buffer.withUnsafeBufferPointer { block in compress(block.baseAddress!) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while count - offset >= 64 {
            compress(base + offset)
            offset += 64
        }
        if offset < count {
            buffer.append(contentsOf: UnsafeBufferPointer(start: base + offset, count: count - offset))
        }
    }

    public mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail: [UInt8] = [0x80]
        let used = (buffer.count + 1) % 64
        let padding = used <= 56 ? 56 - used : 120 - used
        tail.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for shift in stride(from: 0, through: 56, by: 8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        let savedLength = length
        tail.withUnsafeBytes { update(bytes: $0) }
        length = savedLength
        var out: [UInt8] = []
        out.reserveCapacity(16)
        for word in state {
            out.append(UInt8(truncatingIfNeeded: word))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return out
    }

    private mutating func compress(_ block: UnsafePointer<UInt8>) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            m[i] = UInt32(block[i * 4]) | UInt32(block[i * 4 + 1]) << 8 | UInt32(block[i * 4 + 2]) << 16 | UInt32(block[i * 4 + 3]) << 24
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        for i in 0..<64 {
            var f: UInt32
            var g: Int
            switch i {
            case 0..<16:
                f = (b & c) | (~b & d)
                g = i
            case 16..<32:
                f = (d & b) | (~d & c)
                g = (5 * i + 1) % 16
            case 32..<48:
                f = b ^ c ^ d
                g = (3 * i + 5) % 16
            default:
                f = c ^ (b | ~d)
                g = (7 * i) % 16
            }
            f = f &+ a &+ PortableMD5.k[i] &+ m[g]
            a = d
            d = c
            c = b
            b = b &+ ((f << PortableMD5.s[i]) | (f >> (32 - PortableMD5.s[i])))
        }
        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
    }
}
