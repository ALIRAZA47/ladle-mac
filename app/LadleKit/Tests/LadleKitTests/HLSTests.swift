import XCTest
@testable import LadleKit

enum Playlists {
    static let master = """
    #EXTM3U
    #EXT-X-VERSION:6
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio/en/index.m3u8"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Deutsch",LANGUAGE="de",DEFAULT=NO,URI="audio/de/index.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=2500000,AVERAGE-BANDWIDTH=2200000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aac",FRAME-RATE=29.97
    720p/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=12000000,RESOLUTION=3840x2160,CODECS="hvc1.2.4.L150,mp4a.40.2",AUDIO="aac"
    https://cdn.example.org/talks/2160p/index.m3u8
    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=200000,RESOLUTION=1280x720,URI="720p/iframes.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",AUDIO="aac"
    1080p/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"
    audio-only/index.m3u8
    """

    static let fmp4Media = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:6
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:6.000,
    seg-1.m4s
    #EXTINF:6.000,
    seg-2.m4s
    #EXTINF:4.5,
    seg-3.m4s
    #EXT-X-ENDLIST
    """

    static let tsMedia = """
    #EXTM3U
    #EXT-X-TARGETDURATION:10
    #EXT-X-MEDIA-SEQUENCE:0
    #EXT-X-KEY:METHOD=NONE
    #EXTINF:10,
    a.ts
    #EXTINF:10,
    b.ts
    #EXT-X-ENDLIST
    """

    static let encrypted = """
    #EXTM3U
    #EXT-X-TARGETDURATION:10
    #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.org/k1",IV=0x1234
    #EXTINF:10,
    a.ts
    #EXT-X-ENDLIST
    """

    static let live = """
    #EXTM3U
    #EXT-X-TARGETDURATION:4
    #EXT-X-MEDIA-SEQUENCE:120
    #EXTINF:4,
    120.ts
    #EXTINF:4,
    121.ts
    """

    static let byteRanges = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXT-X-MAP:URI="main.mp4",BYTERANGE="720@0"
    #EXTINF:6,
    #EXT-X-BYTERANGE:1000@720
    main.mp4
    #EXTINF:6,
    #EXT-X-BYTERANGE:2000
    main.mp4
    #EXT-X-ENDLIST
    """
}

final class HLSTests: XCTestCase {
    let base = URL(string: "https://videos.example.org/talks/designing-for-speed/master.m3u8")!

    func testParsesMasterPlaylist() throws {
        guard case .master(let master) = try M3U8.parse(Playlists.master, baseURL: base) else { return XCTFail("not a master") }
        XCTAssertEqual(master.variants.count, 4, "I-frame streams are ignored")
        XCTAssertFalse(master.isProtected)
        let sorted = master.sortedVariants
        XCTAssertEqual(sorted.map(\.qualityLabel), ["2160p · 4K", "1080p", "720p", "Audio only"])
        XCTAssertEqual(sorted[2].uri.absoluteString, "https://videos.example.org/talks/designing-for-speed/720p/index.m3u8")
        XCTAssertEqual(sorted[0].uri.absoluteString, "https://cdn.example.org/talks/2160p/index.m3u8")
        XCTAssertEqual(sorted[2].averageBandwidth, 2_200_000)
        XCTAssertEqual(sorted[2].frameRate ?? 0, 29.97, accuracy: 0.001)
        XCTAssertTrue(sorted[3].isAudioOnly)
        let audio = master.audioRendition(for: sorted[1])
        XCTAssertEqual(audio?.name, "English")
        XCTAssertEqual(audio?.uri?.lastPathComponent, "index.m3u8")
        XCTAssertEqual(master.audioOnlyURL?.absoluteString, "https://videos.example.org/talks/designing-for-speed/audio-only/index.m3u8")
    }

    func testParsesFragmentedMP4MediaPlaylist() throws {
        guard case .media(let media) = try M3U8.parse(Playlists.fmp4Media, baseURL: base) else { return XCTFail("not media") }
        XCTAssertEqual(media.segments.count, 3)
        XCTAssertEqual(media.totalDuration, 16.5, accuracy: 0.001)
        XCTAssertEqual(media.map?.uri.lastPathComponent, "init.mp4")
        XCTAssertTrue(media.isComplete)
        XCTAssertFalse(media.isProtected)
        XCTAssertEqual(HLSJoin.container(for: media), .fragmentedMP4)
        XCTAssertEqual(HLSJoin.fileExtension(container: .fragmentedMP4, audioOnly: false), "mp4")
        XCTAssertEqual(HLSJoin.fileExtension(container: .fragmentedMP4, audioOnly: true), "m4a")
    }

    func testTransportStreamsAreSavedAsTS() throws {
        guard case .media(let media) = try M3U8.parse(Playlists.tsMedia, baseURL: base) else { return XCTFail("not media") }
        XCTAssertFalse(media.isProtected, "METHOD=NONE is not protection")
        XCTAssertEqual(HLSJoin.container(for: media), .transportStream)
        XCTAssertEqual(HLSJoin.fileExtension(container: .transportStream, audioOnly: false), "ts")
        XCTAssertEqual(HLSJoin.fileExtension(container: .packedAudio, audioOnly: true, segmentExtension: "mp3"), "mp3")
    }

    func testDetectsProtectedAndLiveStreams() throws {
        guard case .media(let encrypted) = try M3U8.parse(Playlists.encrypted, baseURL: base) else { return XCTFail() }
        XCTAssertTrue(encrypted.isProtected)
        guard case .media(let live) = try M3U8.parse(Playlists.live, baseURL: base) else { return XCTFail() }
        XCTAssertFalse(live.isComplete)
        let sessionKey = Playlists.master.replacingOccurrences(of: "#EXT-X-INDEPENDENT-SEGMENTS", with: "#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI=\"skd://key\",KEYFORMAT=\"com.apple.streamingkeydelivery\"")
        guard case .master(let master) = try M3U8.parse(sessionKey, baseURL: base) else { return XCTFail() }
        XCTAssertTrue(master.isProtected)
    }

    func testByteRanges() throws {
        guard case .media(let media) = try M3U8.parse(Playlists.byteRanges, baseURL: base) else { return XCTFail() }
        XCTAssertEqual(media.map?.byteRange, HLSByteRange(length: 720, offset: 0))
        XCTAssertEqual(media.segments[0].byteRange, HLSByteRange(length: 1000, offset: 720))
        XCTAssertEqual(media.segments[1].byteRange, HLSByteRange(length: 2000, offset: 1720), "continues after the previous range")
        XCTAssertEqual(media.segments[1].byteRange?.lastByte, 3719)
    }

    func testRejectsNonPlaylists() {
        XCTAssertThrowsError(try M3U8.parse("<html></html>", baseURL: base))
        XCTAssertThrowsError(try M3U8.parse("", baseURL: base))
    }

    func testAttributeLists() {
        let a = M3U8.attributes("BANDWIDTH=1,CODECS=\"a,b\",RESOLUTION=1x2,X-Y=0x1F")
        XCTAssertEqual(a["CODECS"], "a,b")
        XCTAssertEqual(a["RESOLUTION"], "1x2")
        XCTAssertEqual(a["X-Y"], "0x1F")
    }

    func testEstimatedSize() {
        XCTAssertEqual(HLSJoin.estimatedSize(bandwidth: 5_000_000, duration: 2538), 1_586_250_000)
        XCTAssertNil(HLSJoin.estimatedSize(bandwidth: 0, duration: 10))
        XCTAssertTrue(HLSJoin.canMergeSeparateAudio(video: .fragmentedMP4, audio: .fragmentedMP4))
        XCTAssertFalse(HLSJoin.canMergeSeparateAudio(video: .transportStream, audio: .fragmentedMP4))
    }
}

final class HLSDownloaderTests: XCTestCase {
    let root = URL(string: "https://videos.example.org/v/")!

    private func serve(_ server: FakeServer, _ path: String, _ text: String) {
        server.serve(URL(string: path, relativeTo: root)!.absoluteURL, FakeFile(data: Data(text.utf8), etag: nil, lastModified: nil))
    }

    func testDownloadsAndJoinsFragmentedMP4() async throws {
        let folder = TempFolder()
        let server = FakeServer()
        serve(server, "media.m3u8", Playlists.fmp4Media)
        let parts = ["init.mp4": "INIT", "seg-1.m4s": "AAAA", "seg-2.m4s": "BBBB", "seg-3.m4s": "CC"]
        for (name, body) in parts { serve(server, name, body) }
        let plans = Locked<[HLSPlanInfo]>([])
        let job = HLSJob(playlistURL: URL(string: "media.m3u8", relativeTo: root)!.absoluteURL, partDirectory: folder.file("talk.mp4.ladle-part"), connections: 3)
        let downloader = HLSDownloader(job: job, transport: server, limiter: TokenBucket(bytesPerSecond: nil), throttle: HostThrottle(), clock: FastClock()) { plan in
            plans.withLock { $0.append(plan) }
            return job.partDirectory
        }
        let outcome = await downloader.run()
        guard case .completed(let video, let audio, let plan) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(audio)
        XCTAssertEqual(plan.container, .fragmentedMP4)
        XCTAssertEqual(plan.segmentCount, 4)
        XCTAssertEqual(plan.fileExtension, "mp4")
        XCTAssertEqual(String(decoding: try Data(contentsOf: video), as: UTF8.self), "INITAAAABBBBCC")
        XCTAssertEqual(downloader.progress().completedSegments, [0, 1, 2, 3])
    }

    func testPicksTheVariantAndItsSeparateAudio() async throws {
        let folder = TempFolder()
        let server = FakeServer()
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="en",DEFAULT=YES,URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="a"
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,AUDIO="a"
        high.m3u8
        """
        serve(server, "master.m3u8", master)
        serve(server, "high.m3u8", "#EXTM3U\n#EXT-X-MAP:URI=\"hi-init.mp4\"\n#EXTINF:5,\nhi1.m4s\n#EXT-X-ENDLIST\n")
        serve(server, "audio.m3u8", "#EXTM3U\n#EXT-X-MAP:URI=\"a-init.mp4\"\n#EXTINF:5,\na1.m4s\n#EXT-X-ENDLIST\n")
        for name in ["hi-init.mp4", "hi1.m4s", "a-init.mp4", "a1.m4s"] { serve(server, name, name.uppercased()) }
        let job = HLSJob(playlistURL: URL(string: "master.m3u8", relativeTo: root)!.absoluteURL, partDirectory: folder.file("v.ladle-part"), qualityLabel: "1080p")
        let downloader = HLSDownloader(job: job, transport: server, limiter: TokenBucket(bytesPerSecond: nil), throttle: HostThrottle(), clock: FastClock()) { _ in job.partDirectory }
        guard case .completed(let video, let audio, let plan) = await downloader.run() else { return XCTFail() }
        XCTAssertEqual(String(decoding: try Data(contentsOf: video), as: UTF8.self), "HI-INIT.MP4HI1.M4S")
        XCTAssertEqual(String(decoding: try Data(contentsOf: XCTUnwrap(audio)), as: UTF8.self), "A-INIT.MP4A1.M4S")
        XCTAssertEqual(plan.audioContainer, .fragmentedMP4)
        XCTAssertEqual(plan.estimatedTotal, 3_125_000, "5 Mb/s for 5 s")
        XCTAssertFalse(server.requests.contains { $0.url.lastPathComponent == "low.m3u8" })
    }

    func testRefusesProtectedVideo() async {
        let folder = TempFolder()
        let server = FakeServer()
        serve(server, "media.m3u8", Playlists.encrypted)
        let job = HLSJob(playlistURL: URL(string: "media.m3u8", relativeTo: root)!.absoluteURL, partDirectory: folder.file("p.ladle-part"))
        let downloader = HLSDownloader(job: job, transport: server, limiter: TokenBucket(bytesPerSecond: nil), throttle: HostThrottle(), clock: FastClock()) { _ in job.partDirectory }
        let outcome = await downloader.run()
        XCTAssertEqual(outcome, .failed(DownloadFailure(.protectedVideo)))
        XCTAssertFalse(server.requests.contains { $0.url.pathExtension == "ts" }, "not a single segment is fetched")
    }

    func testRefusesLiveStreams() async {
        let folder = TempFolder()
        let server = FakeServer()
        serve(server, "media.m3u8", Playlists.live)
        let job = HLSJob(playlistURL: URL(string: "media.m3u8", relativeTo: root)!.absoluteURL, partDirectory: folder.file("p.ladle-part"))
        let downloader = HLSDownloader(job: job, transport: server, limiter: TokenBucket(bytesPerSecond: nil), throttle: HostThrottle(), clock: FastClock()) { _ in job.partDirectory }
        let outcome = await downloader.run()
        XCTAssertEqual(outcome, .failed(DownloadFailure(.liveStream)))
    }

    func testByteRangeSegmentsAndResume() async throws {
        let folder = TempFolder()
        let server = FakeServer()
        serve(server, "media.m3u8", "#EXTM3U\n#EXTINF:5,\n#EXT-X-BYTERANGE:4@2\nall.ts\n#EXTINF:5,\n#EXT-X-BYTERANGE:3\nall.ts\n#EXT-X-ENDLIST\n")
        server.serve(URL(string: "all.ts", relativeTo: root)!.absoluteURL, FakeFile(data: Data("..ABCDEFG..".utf8)))
        let partDir = folder.file("r.ladle-part")
        try FileManager.default.createDirectory(at: partDir, withIntermediateDirectories: true)
        // Segment 0 is already on disk from an earlier run.
        try Data("ABCD".utf8).write(to: partDir.appendingPathComponent("000000.seg"))
        let job = HLSJob(playlistURL: URL(string: "media.m3u8", relativeTo: root)!.absoluteURL, partDirectory: partDir, completedSegments: [0], segmentCount: 2)
        let downloader = HLSDownloader(job: job, transport: server, limiter: TokenBucket(bytesPerSecond: nil), throttle: HostThrottle(), clock: FastClock()) { _ in partDir }
        guard case .completed(let video, _, let plan) = await downloader.run() else { return XCTFail() }
        XCTAssertEqual(plan.container, .transportStream)
        XCTAssertEqual(String(decoding: try Data(contentsOf: video), as: UTF8.self), "ABCDEFG")
        let segmentRequests = server.requests.filter { $0.url.lastPathComponent == "all.ts" }
        XCTAssertEqual(segmentRequests.count, 1, "the finished segment isn't fetched again")
        XCTAssertEqual(segmentRequests.first?.rangeHeader, "bytes=6-8")
    }
}
