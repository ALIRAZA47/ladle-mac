import XCTest
@testable import LadleKit

final class BridgeTests: XCTestCase {
    func testFramingRoundTrip() throws {
        let one = Data(#"{"type":"hello"}"#.utf8)
        let two = Data(#"{"type":"download","url":"https://a.org/x.zip"}"#.utf8)
        var buffer = NativeMessaging.frame(one) + NativeMessaging.frame(two)
        XCTAssertEqual(buffer.prefix(4), Data([UInt8(one.count), 0, 0, 0]), "32-bit little-endian length")
        // A partial third message stays in the buffer.
        buffer.append(NativeMessaging.frame(one).prefix(6))
        let frames = try NativeMessaging.takeFrames(from: &buffer)
        XCTAssertEqual(frames, [one, two])
        XCTAssertEqual(buffer.count, 6)
        buffer.append(NativeMessaging.frame(one).dropFirst(6))
        XCTAssertEqual(try NativeMessaging.takeFrames(from: &buffer), [one])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testRefusesHugeFrames() {
        var buffer = Data([0xff, 0xff, 0xff, 0x7f])
        XCTAssertThrowsError(try NativeMessaging.takeFrames(from: &buffer))
    }

    func testDecodesExtensionMessages() throws {
        let json = #"""
        {"id":7,"type":"download","url":"https://handbrake.fr/rotation.php?file=HandBrake-1.8.2.dmg","filename":"HandBrake-1.8.2.dmg",
         "referrer":"https://handbrake.fr/downloads.php","cookies":"a=1","size":84600000,"mime":"application/x-apple-diskimage",
         "mode":"caught","browser":"Chrome","userAgent":"Mozilla/5.0"}
        """#
        let request = try JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
        let handOff = try XCTUnwrap(request.handOff(source: nil))
        XCTAssertEqual(handOff.urls.first?.host, "handbrake.fr")
        XCTAssertEqual(handOff.fileName, "HandBrake-1.8.2.dmg")
        XCTAssertEqual(handOff.size, 84_600_000)
        XCTAssertEqual(handOff.cookies, "a=1")
        XCTAssertEqual(handOff.mode, .caught)
        XCTAssertEqual(handOff.source, "Chrome")
        XCTAssertNil(try JSONDecoder().decode(BridgeRequest.self, from: Data(#"{"type":"hello"}"#.utf8)).handOff(source: nil))
        XCTAssertNil(try JSONDecoder().decode(BridgeRequest.self, from: Data(#"{"type":"download","url":"javascript:alert(1)"}"#.utf8)).handOff(source: nil))
    }

    func testVideoAndLinkListMessages() throws {
        var video = BridgeRequest(type: "video")
        video.url = "https://videos.example.org/talks/1080p/index.m3u8"
        video.kind = "hls"
        video.title = "Designing for Speed"
        video.quality = "1080p"
        video.audio = "https://videos.example.org/talks/audio/index.m3u8"
        let v = try XCTUnwrap(video.handOff(source: "Firefox"))
        XCTAssertEqual(v.kind, .hls)
        XCTAssertEqual(v.mode, .direct, "the video button is an explicit choice")
        XCTAssertEqual(v.audioURL?.lastPathComponent, "index.m3u8")
        let requests = DownloadRequest.from(v)
        XCTAssertEqual(requests.first?.initialName, "Designing for Speed.mp4")

        var links = BridgeRequest(type: "links")
        links.links = ["https://a.org/1.zip", "https://a.org/1.zip", "mailto:x@y.z", "https://a.org/2.zip"]
        let l = try XCTUnwrap(links.handOff(source: "Safari"))
        XCTAssertEqual(l.urls.count, 2)
        XCTAssertTrue(l.isBatch)

        // A page with one file link still opens the Add sheet, and the choice survives ladle://.
        links.links = ["https://a.org/only.pdf"]
        let one = try XCTUnwrap(links.handOff(source: "Safari"))
        XCTAssertEqual(one.mode, .choose)
        XCTAssertTrue(one.isBatch)
        let back = try XCTUnwrap(LadleURL.make(one).flatMap(LadleURL.parse))
        XCTAssertEqual(back.mode, .choose)
        XCTAssertTrue(back.isBatch)
    }

    func testSettingsSnapshotForTheExtension() throws {
        var settings = Settings()
        settings.alwaysDownloadTypes = ["dmg"]
        let home = URL(fileURLWithPath: "/Users/ali")
        let snapshot = BrowserSettingsSnapshot(settings: settings, appVersion: "1.0.0", token: "t", home: home)
        XCTAssertEqual(snapshot.saveFolder, "Downloads › Ladle")
        XCTAssertEqual(snapshot.videoFolder, "Downloads › Ladle › Video")
        XCTAssertEqual(snapshot.catchTypes.first, "dmg")
        let json = String(decoding: try NativeMessaging.encode(BridgeReply(replyTo: 1, ok: true, settings: snapshot)), as: UTF8.self)
        XCTAssertTrue(json.contains(#""askBeforeDownloading":true"#))
        XCTAssertTrue(json.contains(#""replyTo":1"#))
    }

    func testHostManifests() throws {
        let chrome = try JSONSerialization.jsonObject(with: NativeHostManifest.json(
            for: .chrome, bridgePath: "/Applications/Ladle.app/Contents/MacOS/LadleBridge",
            chromeOrigins: ["abcdefghijklmnopabcdefghijklmnop"], firefoxIDs: ["ladle@alirazakhan.me"]
        )) as? [String: Any]
        XCTAssertEqual(chrome?["name"] as? String, "me.alirazakhan.ladle")
        XCTAssertEqual(chrome?["type"] as? String, "stdio")
        XCTAssertEqual(chrome?["allowed_origins"] as? [String], ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"])
        XCTAssertNil(chrome?["allowed_extensions"])
        let firefox = try JSONSerialization.jsonObject(with: NativeHostManifest.json(
            for: .firefox, bridgePath: "/x", chromeOrigins: [], firefoxIDs: ["ladle@alirazakhan.me"]
        )) as? [String: Any]
        XCTAssertEqual(firefox?["allowed_extensions"] as? [String], ["ladle@alirazakhan.me"])

        let folder = TempFolder()
        let written = try NativeHostManifest.install(for: [.chrome, .brave, .arc, .firefox], home: folder.url, bridgePath: "/b", chromeOrigins: ["x"], firefoxIDs: ["y"])
        XCTAssertEqual(written.map { $0.path.replacingOccurrences(of: folder.url.path, with: "~") }, [
            "~/Library/Application Support/Google/Chrome/NativeMessagingHosts/me.alirazakhan.ladle.json",
            "~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/me.alirazakhan.ladle.json",
            "~/Library/Application Support/Arc/User Data/NativeMessagingHosts/me.alirazakhan.ladle.json",
            "~/Library/Application Support/Mozilla/NativeMessagingHosts/me.alirazakhan.ladle.json",
        ])
        XCTAssertTrue(NativeHostManifest.isInstalled(for: .brave, home: folder.url, bridgePath: "/b"))
        XCTAssertFalse(NativeHostManifest.isInstalled(for: .brave, home: folder.url, bridgePath: "/moved"))
        XCTAssertFalse(NativeHostManifest.isInstalled(for: .edge, home: folder.url, bridgePath: "/b"))
        XCTAssertTrue(NativeHostManifest.isCurrent(for: .brave, home: folder.url, bridgePath: "/b", chromeOrigins: ["x"], firefoxIDs: ["y"]))
        XCTAssertFalse(NativeHostManifest.isCurrent(for: .brave, home: folder.url, bridgePath: "/b", chromeOrigins: ["x", "store"], firefoxIDs: ["y"]), "a new store ID needs a rewrite")
        XCTAssertTrue(NativeHostManifest.isCurrent(for: .firefox, home: folder.url, bridgePath: "/b", chromeOrigins: ["other"], firefoxIDs: ["y"]))
        XCTAssertFalse(NativeHostManifest.isCurrent(for: .edge, home: folder.url, bridgePath: "/b", chromeOrigins: ["x"], firefoxIDs: ["y"]))
    }
}
