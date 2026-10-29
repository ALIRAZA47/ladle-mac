import Foundation

/// Streaming SHA-256 (FIPS 180-4) in plain Swift, for platforms without CryptoKit.
public struct PortableSHA256: Sendable {
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

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
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        let savedLength = length
        tail.withUnsafeBytes { update(bytes: $0) }
        length = savedLength
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in state {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }

    private mutating func compress(_ block: UnsafePointer<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let b0 = UInt32(block[i * 4]) << 24
            let b1 = UInt32(block[i * 4 + 1]) << 16
            let b2 = UInt32(block[i * 4 + 2]) << 8
            let b3 = UInt32(block[i * 4 + 3])
            w[i] = b0 | b1 | b2 | b3
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ PortableSHA256.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h = g
            g = f
            f = e
            e = d &+ t1
            d = c
            c = b
            b = a
            a = t1 &+ t2
        }
        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
        state[5] = state[5] &+ f
        state[6] = state[6] &+ g
        state[7] = state[7] &+ h
    }

    @inline(__always)
    private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
