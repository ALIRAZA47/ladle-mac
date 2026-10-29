import XCTest
@testable import LadleKit

final class ChecksumTests: XCTestCase {
    private func portable(_ data: Data, _ algorithm: ChecksumAlgorithm) -> String {
        switch algorithm {
        case .sha256:
            var digest = PortableSHA256()
            digest.update(data)
            return Checksums.hex(digest.finalize())
        case .md5:
            var digest = PortableMD5()
            digest.update(data)
            return Checksums.hex(digest.finalize())
        }
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(portable(Data(), .sha256), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(portable(Data("abc".utf8), .sha256), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            portable(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8), .sha256),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        XCTAssertEqual(portable(Data(repeating: 0x61, count: 1_000_000), .sha256), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testMD5KnownVectors() {
        XCTAssertEqual(portable(Data(), .md5), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(portable(Data("abc".utf8), .md5), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(portable(Data("message digest".utf8), .md5), "f96b697d7cb7938d525a2f31aaf161d0")
        XCTAssertEqual(portable(Data("The quick brown fox jumps over the lazy dog".utf8), .md5), "9e107d9d372bb6826bd81d3542a419d6")
        XCTAssertEqual(portable(Data(repeating: 0x61, count: 1_000_000), .md5), "7707d6ae4e027c70eea2a935c2296f21")
    }

    func testBlockBoundaries() {
        let expected: [Int: (String, String)] = [
            55: ("e7313d333c272e639f790978283f9eb392e843d0f29b7016828bb1daa4aac70b", "52c0e574e1198de5fe3f8f11440dcb1b"),
            56: ("4324d65f3c103567f5589c710bc08f8523f929a9272e3af36fc968e52abc6c27", "46c9907fc908ee68b1e7b8e71286a518"),
            57: ("35df609437dcfea3279283ab79fd554e2bf78f8f7ae2de532d8ee300b09e8f73", "1c805dd236c35cab25fcb1bc73802c51"),
            63: ("81c80242132f230c3bd41b3e63bbcff16107339549214a99614ff26664625055", "a62f6d59e837867693f042f5b8f5a236"),
            64: ("39e3d7b6b5d075d37d053ad89b24b41bef4f3c29760c84447cab3f3be1882241", "7160b8fb5e9e4023d549c3971fbaeead"),
            65: ("aacca6ff74fdbb296d165a45cecfa04e5127bc008770fbbdd48006f2d2fae95e", "70bd662e7aefbda85a0f7244167b7897"),
            119: ("9ce7368e4daf32341631b492e80359dc9f594b48453cd0dd5bf0b19279cc177e", "e84905d4214f4d1ca56c2cdcc152b143"),
            120: ("7836b787757e95e58b3ca5aec90b1b004e8deba1e50e9675af9cabf1a13a04b5", "e3eb5a6c8669ea01a8c185b8abc8a5dc"),
            1000: ("1e9bc38cbf860b9ec31918b065f9b52476c549a782e0e7990bed8ce3868d2371", "10046f077f2082ac19676b8079f1cb1a"),
        ]
        for (count, sums) in expected {
            let data = Data((0..<count).map { UInt8(($0 * 7 + 3) % 256) })
            XCTAssertEqual(portable(data, .sha256), sums.0, "SHA-256 of \(count) bytes")
            XCTAssertEqual(portable(data, .md5), sums.1, "MD5 of \(count) bytes")
        }
    }

    func testStreamingInOddChunksMatchesOneShot() {
        let data = TestData.bytes(10_007)
        var sha = PortableSHA256()
        var md5 = PortableMD5()
        var offset = 0
        var size = 1
        while offset < data.count {
            let end = min(data.count, offset + size)
            sha.update(data.subdata(in: offset..<end))
            md5.update(data.subdata(in: offset..<end))
            offset = end
            size = size * 3 % 97 + 1
        }
        XCTAssertEqual(Checksums.hex(sha.finalize()), portable(data, .sha256))
        XCTAssertEqual(Checksums.hex(md5.finalize()), portable(data, .md5))
    }

    func testFileDigestAndVerify() throws {
        let folder = TempFolder()
        let file = folder.file("node-v22.11.0.pkg")
        let data = TestData.bytes(3_000_000)
        try data.write(to: file)
        let sha = try Checksums.digest(ofFileAt: file, algorithm: .sha256, portableOnly: true)
        XCTAssertEqual(sha, portable(data, .sha256))
        // The default hasher (CryptoKit on the Mac) agrees with the portable one.
        XCTAssertEqual(try Checksums.digest(ofFileAt: file, algorithm: .sha256), sha)
        XCTAssertEqual(try Checksums.digest(ofFileAt: file, algorithm: .md5), portable(data, .md5))
        XCTAssertTrue(try Checksums.verify(fileAt: file, expected: ExpectedChecksum(algorithm: .sha256, value: sha.uppercased(), source: .pasted)))
        XCTAssertFalse(try Checksums.verify(fileAt: file, expected: ExpectedChecksum(algorithm: .sha256, value: String(repeating: "0", count: 64), source: .pasted)))
    }

    func testParsesChecksumTokens() {
        let sha = String(repeating: "ab", count: 32)
        XCTAssertEqual(ExpectedChecksum.parse(sha, source: .pasted)?.algorithm, .sha256)
        XCTAssertEqual(ExpectedChecksum.parse("SHA256:" + sha.uppercased(), source: .pasted)?.value, sha)
        XCTAssertEqual(ExpectedChecksum.parse("md5:" + String(repeating: "c", count: 32), source: .pasted)?.algorithm, .md5)
        XCTAssertNil(ExpectedChecksum.parse("md5:" + sha, source: .pasted), "prefix and length must agree")
        XCTAssertNil(ExpectedChecksum.parse("not-a-hash", source: .pasted))
        XCTAssertNil(ExpectedChecksum.parse(String(repeating: "g", count: 64), source: .pasted))
    }

    func testParsesSidecarFiles() {
        let a = String(repeating: "1", count: 64)
        let b = String(repeating: "2", count: 64)
        XCTAssertEqual(Checksums.parseSidecar(a + "\n", fileName: "x.iso")?.value, a)
        XCTAssertEqual(Checksums.parseSidecar("\(a)  other.iso\n\(b) *ubuntu.iso\n", fileName: "ubuntu.iso")?.value, b)
        XCTAssertEqual(Checksums.parseSidecar("\(a)  ubuntu.iso", fileName: "ubuntu.iso")?.source, .sidecar)
        XCTAssertEqual(Checksums.parseSidecar("SHA256 (ubuntu.iso) = \(b)", fileName: "ubuntu.iso")?.value, b)
        XCTAssertNil(Checksums.parseSidecar("<html>Not found</html>", fileName: "x.iso"))
        XCTAssertNil(Checksums.parseSidecar("\(a)  other.iso\n\(b)  third.iso\n", fileName: "x.iso"), "a list naming other files isn't ours")
    }
}
