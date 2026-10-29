import XCTest
@testable import LadleKit

final class LinkTests: XCTestCase {
    func testRecognizesSingleLinks() {
        XCTAssertEqual(LinkParser.link(from: "  https://media.example.org/films/big-buck-bunny-2160p.mp4 \n")?.host, "media.example.org")
        XCTAssertNotNil(LinkParser.link(from: "<http://example.com/a.zip>"))
        XCTAssertNil(LinkParser.link(from: "ftp://example.com/a.zip"))
        XCTAssertNil(LinkParser.link(from: "example.com/a.zip"))
        XCTAssertNil(LinkParser.link(from: "https://"))
        XCTAssertNil(LinkParser.link(from: "https://example.com/a.zip and more"))
        XCTAssertNil(LinkParser.link(from: "big buck bunny"))
    }

    func testExpandsSeriesKeepingZeroPadding() {
        let episodes = LinkParser.expandSeries("https://cdn.example.fm/ep-[01-12].mp3")
        XCTAssertEqual(episodes.count, 12)
        XCTAssertEqual(episodes.first, "https://cdn.example.fm/ep-01.mp3")
        XCTAssertEqual(episodes[8], "https://cdn.example.fm/ep-09.mp3")
        XCTAssertEqual(episodes.last, "https://cdn.example.fm/ep-12.mp3")

        let images = LinkParser.expandSeries("https://x.org/img[1-20].jpg")
        XCTAssertEqual(images.count, 20)
        XCTAssertEqual(images[0], "https://x.org/img1.jpg")
        XCTAssertEqual(images[19], "https://x.org/img20.jpg")

        XCTAssertEqual(LinkParser.expandSeries("a[001-003]"), ["a001", "a002", "a003"])
        XCTAssertEqual(LinkParser.expandSeries("a[3-1]"), ["a3", "a2", "a1"], "counts down too")
        XCTAssertEqual(LinkParser.expandSeries("s[1-2]e[01-02]"), ["s1e01", "s1e02", "s2e01", "s2e02"])
        XCTAssertEqual(LinkParser.expandSeries("ep-[140-150].mp3").count, 11)
    }

    func testLeavesOtherBracketsAlone() {
        XCTAssertEqual(LinkParser.expandSeries("file[a-b].zip"), ["file[a-b].zip"])
        XCTAssertEqual(LinkParser.expandSeries("file[1].zip"), ["file[1].zip"])
        XCTAssertEqual(LinkParser.expandSeries("x[1-99999]"), ["x[1-99999]"], "too long a series is not expanded")
        XCTAssertFalse(LinkParser.containsSeries("https://a.org/[x]"))
        XCTAssertTrue(LinkParser.containsSeries("https://a.org/[1-2]"))
    }

    func testParsesManyLinksWithChecksums() {
        let sha = String(repeating: "a", count: 64)
        let text = """
        https://cdn.example.fm/the-long-take/ep-143.mp3
        https://cdn.example.fm/the-long-take/ep-144.mp3

        https://investors.example.com/reports/annual-report-2025.pdf \(sha)
        not a link
        https://media.example.edu/cs-341/lecture-08-consensus.mp4  https://media.example.edu/cs-341/lecture-09.mp4
        https://cdn.example.fm/the-long-take/ep-143.mp3
        https://x.org/ep-[1-3].mp3 \(sha)
        """
        let links = LinkParser.parseBatch(text)
        XCTAssertEqual(links.map { $0.url.lastPathComponent }, [
            "ep-143.mp3", "ep-144.mp3", "annual-report-2025.pdf", "lecture-08-consensus.mp4", "lecture-09.mp4",
            "ep-1.mp3", "ep-2.mp3", "ep-3.mp3",
        ])
        XCTAssertEqual(links[2].checksum?.value, sha)
        XCTAssertNil(links[0].checksum)
        XCTAssertNil(links[5].checksum, "a series doesn't share one checksum")
    }

    func testClipboardOffersOnlyFileLinks() {
        let detector = ClipboardDetector()
        XCTAssertEqual(detector.candidate(in: "https://media.example.org/films/big-buck-bunny-2160p.mp4")?.lastPathComponent, "big-buck-bunny-2160p.mp4")
        XCTAssertNotNil(detector.candidate(in: "https://cdn.example.fm/the-long-take/ep-145.MP3"))
        XCTAssertNil(detector.candidate(in: "https://example.com/blog/post"))
        XCTAssertNil(detector.candidate(in: "https://example.com/page.html"))
        XCTAssertNil(detector.candidate(in: "Read https://example.com/a.zip later"))
        XCTAssertNil(detector.candidate(in: nil))
        XCTAssertNil(detector.candidate(in: "https://a.org/x.zip", existing: ["https://a.org/x.zip"]))
        XCTAssertNil(detector.candidate(in: "https://a.org/x.zip", dismissed: ["https://a.org/x.zip"]))
        XCTAssertNil(detector.candidate(in: String(repeating: "x", count: 5000)))
    }

    func testURLSchemeRoundTrip() throws {
        let sha = String(repeating: "f", count: 64)
        let handOff = HandOff(
            urls: [URL(string: "https://handbrake.fr/dl/HandBrake-1.8.2.dmg?x=1&y=a+b")!],
            referrer: URL(string: "https://handbrake.fr/downloads.php")!,
            fileName: "HandBrake-1.8.2.dmg",
            cookies: "session=a=b; theme=dark",
            size: 84_600_000,
            checksum: ExpectedChecksum(algorithm: .sha256, value: sha, source: .browser),
            source: "Safari",
            token: "secret"
        )
        let url = try XCTUnwrap(LadleURL.make(handOff))
        XCTAssertEqual(url.scheme, "ladle")
        XCTAssertEqual(url.host, "add")
        let parsed = try XCTUnwrap(LadleURL.parse(url))
        XCTAssertEqual(parsed, handOff)
    }

    func testParsesTheSpecURLShape() throws {
        let url = URL(string: "ladle://add?url=https%3A%2F%2Fexample.com%2Ffile.zip&referrer=https%3A%2F%2Fexample.com%2F&filename=file.zip&cookies=a%3D1%3B%20b%3D2")!
        let handOff = try XCTUnwrap(LadleURL.parse(url))
        XCTAssertEqual(handOff.urls, [URL(string: "https://example.com/file.zip")!])
        XCTAssertEqual(handOff.cookies, "a=1; b=2")
        XCTAssertEqual(handOff.fileName, "file.zip")
        XCTAssertEqual(handOff.mode, .caught)
        XCTAssertNil(handOff.token)
        XCTAssertNil(LadleURL.parse(URL(string: "ladle://add")!))
        XCTAssertNil(LadleURL.parse(URL(string: "ladle://delete?url=https%3A%2F%2Fa.org%2Fx")!))
        XCTAssertNil(LadleURL.parse(URL(string: "https://add?url=x")!))
    }

    func testURLSchemeCarriesLists() throws {
        let url = URL(string: "ladle://add?url=https%3A%2F%2Fa.org%2F1.zip&url=https%3A%2F%2Fa.org%2F2.zip&url=nope")!
        let handOff = try XCTUnwrap(LadleURL.parse(url))
        XCTAssertEqual(handOff.urls.count, 2)
        XCTAssertTrue(handOff.isBatch)
    }

    func testReadsWeblocFiles() throws {
        let plist: [String: Any] = ["URL": "https://releases.ubuntu.com/24.04/ubuntu.iso"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(Webloc.url(fromData: data)?.lastPathComponent, "ubuntu.iso")
        let binary = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertEqual(Webloc.url(fromData: binary)?.host, "releases.ubuntu.com")
        XCTAssertNil(Webloc.url(fromData: Data("junk".utf8)))
    }
}
