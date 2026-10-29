import Foundation

/// Settings the browser extension needs, written by the app to `browser-settings.json` so the
/// native messaging helper and the Safari extension can answer without the app running.
public struct BrowserSettingsSnapshot: Codable, Equatable, Sendable {
    public var catchTypes: [String]
    public var askBeforeDownloading: Bool
    public var alwaysTypes: [String]
    /// "Downloads › Ladle"
    public var saveFolder: String
    /// "Downloads › Ladle › Video", shown in the video button's menu.
    public var videoFolder: String
    public var appVersion: String
    /// A random secret. `ladle://` links carrying it come from Ladle's own extension.
    public var token: String

    public init(settings: Settings, appVersion: String, token: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        catchTypes = settings.catchFileTypes
        askBeforeDownloading = settings.askBeforeDownloading
        alwaysTypes = settings.alwaysDownloadTypes
        saveFolder = Destination.displayPath(settings.saveFolder(home: home).path, home: home)
        videoFolder = Destination.displayPath(Destination.folder(for: .video, settings: settings, home: home).path, home: home)
        self.appVersion = appVersion
        self.token = token
    }
}

/// A message from the extension. One flat shape for every type keeps the JavaScript side simple.
///
/// Types: `hello`, `download` (one link; `mode` "caught" or "direct"), `links` (a list for the
/// add sheet), `video` (the video button: `kind` "hls" or "file").
public struct BridgeRequest: Codable, Equatable, Sendable {
    public var id: Int?
    public var type: String
    public var browser: String?
    public var version: String?
    public var url: String?
    public var filename: String?
    public var referrer: String?
    public var cookies: String?
    public var size: Int64?
    public var mime: String?
    public var userAgent: String?
    public var mode: String?
    public var sha256: String?
    public var md5: String?
    public var links: [String]?
    public var kind: String?
    public var audio: String?
    public var title: String?
    public var quality: String?
    public var bandwidth: Int?

    public init(type: String, id: Int? = nil) {
        self.type = type
        self.id = id
    }

    /// The download this message asks for, or nil for `hello` and malformed messages.
    public func handOff(source: String?) -> HandOff? {
        let urls: [URL]
        switch type {
        case "download", "video":
            guard let link = url.flatMap(LinkParser.link(from:)) else { return nil }
            urls = [link]
        case "links":
            var seen = Set<String>()
            urls = (links ?? []).compactMap(LinkParser.link(from:)).filter { seen.insert($0.absoluteString).inserted }
            guard !urls.isEmpty else { return nil }
        default:
            return nil
        }
        var checksum: ExpectedChecksum?
        if let sha256 { checksum = ExpectedChecksum.parse("sha256:" + sha256, source: .browser) }
        if checksum == nil, let md5 { checksum = ExpectedChecksum.parse("md5:" + md5, source: .browser) }
        let isVideo = type == "video"
        return HandOff(
            urls: urls,
            referrer: referrer.flatMap(LinkParser.link(from:)),
            fileName: filename.map { FileNaming.sanitize($0) }.flatMap { $0.isEmpty ? nil : $0 },
            cookies: cookies.flatMap { $0.isEmpty ? nil : $0 },
            size: size.flatMap { $0 > 0 ? $0 : nil },
            mimeType: mime,
            checksum: checksum,
            source: browser ?? source,
            mode: isVideo ? .direct : (mode.flatMap(HandOff.Mode.init(rawValue:)) ?? .caught),
            kind: isVideo && kind == "hls" ? .hls : .file,
            audioURL: audio.flatMap(LinkParser.link(from:)),
            title: title,
            quality: quality,
            bandwidth: bandwidth
        )
    }
}

public struct BridgeReply: Codable, Equatable, Sendable {
    public var replyTo: Int?
    public var ok: Bool
    public var error: String?
    public var settings: BrowserSettingsSnapshot?

    public init(replyTo: Int?, ok: Bool, error: String? = nil, settings: BrowserSettingsSnapshot? = nil) {
        self.replyTo = replyTo
        self.ok = ok
        self.error = error
        self.settings = settings
    }
}

/// A message from the app to the extension, sent through the helper.
public struct BridgePush: Codable, Equatable, Sendable {
    /// `browserDownload`: "Let the browser handle it". `settings`: something changed.
    public var type: String
    public var url: String?
    public var filename: String?
    public var referrer: String?
    public var settings: BrowserSettingsSnapshot?

    public init(type: String, url: String? = nil, filename: String? = nil, referrer: String? = nil, settings: BrowserSettingsSnapshot? = nil) {
        self.type = type
        self.url = url
        self.filename = filename
        self.referrer = referrer
        self.settings = settings
    }
}

/// What the helper sends to the app over the local message port.
public struct BridgeEnvelope: Codable, Equatable, Sendable {
    /// The helper's own port, for pushes back to this browser.
    public var replyPort: String?
    /// The browser that started the helper ("Chrome", "Firefox"…).
    public var browser: String?
    public var request: BridgeRequest

    public init(replyPort: String?, browser: String?, request: BridgeRequest) {
        self.replyPort = replyPort
        self.browser = browser
        self.request = request
    }
}

/// Chrome and Firefox native messaging framing: a 32-bit little-endian length, then UTF-8 JSON.
public enum NativeMessaging {
    /// Larger messages are refused.
    public static let maxMessageSize = 8 << 20

    public static func frame(_ json: Data) -> Data {
        var length = UInt32(json.count).littleEndian
        var data = Data(bytes: &length, count: 4)
        data.append(json)
        return data
    }

    public enum FrameError: Error, Equatable {
        case tooLarge(Int)
    }

    /// Removes complete messages from the front of `buffer` and returns them.
    public static func takeFrames(from buffer: inout Data) throws -> [Data] {
        var frames: [Data] = []
        while buffer.count >= 4 {
            let b = [UInt8](buffer.prefix(4))
            let length = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
            guard length <= maxMessageSize else { throw FrameError.tooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex + 4
            frames.append(Data(buffer[start..<(start + length)]))
            buffer = Data(buffer[(start + length)...])
        }
        return frames
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
