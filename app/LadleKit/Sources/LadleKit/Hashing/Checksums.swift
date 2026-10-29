import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Hashing files to verify published checksums.
public enum Checksums {
    public static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return out
    }

    public static func digest(of data: Data, algorithm: ChecksumAlgorithm) -> String {
        var hasher = ChecksumHasher(algorithm: algorithm)
        hasher.update(data)
        return hasher.finalizeHex()
    }

    /// Hashes a file in 1 MiB reads. Checks for cancellation between reads.
    public static func digest(ofFileAt url: URL, algorithm: ChecksumAlgorithm, portableOnly: Bool = false) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = ChecksumHasher(algorithm: algorithm, portableOnly: portableOnly)
        while true {
            if Task.isCancelled { throw CancellationError() }
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return hasher.finalizeHex()
    }

    public static func verify(fileAt url: URL, expected: ExpectedChecksum) throws -> Bool {
        try digest(ofFileAt: url, algorithm: expected.algorithm) == expected.value.lowercased()
    }

    /// Reads a `<file>.sha256` sidecar. Accepts a bare digest or `sha256sum` lines ("<hex>  <name>"),
    /// preferring the line that names `fileName`.
    public static func parseSidecar(_ text: String, fileName: String, algorithm: ChecksumAlgorithm = .sha256) -> ExpectedChecksum? {
        var fallback: ExpectedChecksum?
        var lines = 0
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            lines += 1
            if lines > 2000 { break }
            // BSD style: "SHA256 (name) = hex"
            if line.uppercased().hasPrefix("SHA256 ("), let eq = line.range(of: ") = ") {
                let name = String(line[line.index(line.startIndex, offsetBy: 8)..<eq.lowerBound])
                let digest = String(line[eq.upperBound...])
                if let sum = ExpectedChecksum.parse(digest, source: .sidecar), sum.algorithm == algorithm {
                    if name == fileName { return sum }
                    if fallback == nil { fallback = sum }
                }
                continue
            }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = tokens.first, let sum = ExpectedChecksum.parse(first, source: .sidecar), sum.algorithm == algorithm else { continue }
            if tokens.count >= 2 {
                var name = tokens[1...].joined(separator: " ")
                if name.hasPrefix("*") { name.removeFirst() }
                if name == fileName || (name as NSString).lastPathComponent == fileName { return sum }
                if fallback == nil && lines == 1 { fallback = sum }
            } else if fallback == nil {
                fallback = sum
            }
        }
        return fallback
    }
}

/// Incremental hasher that uses CryptoKit where it exists and the portable code elsewhere.
public struct ChecksumHasher {
    private enum Engine {
        case sha(PortableSHA256)
        case md5(PortableMD5)
        #if canImport(CryptoKit)
        case cryptoSHA(CryptoKit.SHA256)
        case cryptoMD5(Insecure.MD5)
        #endif
    }

    private var engine: Engine

    public init(algorithm: ChecksumAlgorithm, portableOnly: Bool = false) {
        #if canImport(CryptoKit)
        if !portableOnly {
            switch algorithm {
            case .sha256: engine = .cryptoSHA(CryptoKit.SHA256())
            case .md5: engine = .cryptoMD5(Insecure.MD5())
            }
            return
        }
        #endif
        switch algorithm {
        case .sha256: engine = .sha(PortableSHA256())
        case .md5: engine = .md5(PortableMD5())
        }
    }

    public mutating func update(_ data: Data) {
        switch engine {
        case .sha(var digest):
            digest.update(data)
            engine = .sha(digest)
        case .md5(var digest):
            digest.update(data)
            engine = .md5(digest)
        #if canImport(CryptoKit)
        case .cryptoSHA(var digest):
            digest.update(data: data)
            engine = .cryptoSHA(digest)
        case .cryptoMD5(var digest):
            digest.update(data: data)
            engine = .cryptoMD5(digest)
        #endif
        }
    }

    public mutating func finalizeHex() -> String {
        switch engine {
        case .sha(var digest):
            return Checksums.hex(digest.finalize())
        case .md5(var digest):
            return Checksums.hex(digest.finalize())
        #if canImport(CryptoKit)
        case .cryptoSHA(let digest):
            return Checksums.hex(Array(digest.finalize()))
        case .cryptoMD5(let digest):
            return Checksums.hex(Array(digest.finalize()))
        #endif
        }
    }
}
