import Foundation

/// A request the browser extension (or anything else) hands to Ladle.
/// Travels as `ladle://add?…` or as a native message; both decode to this.
public struct HandOff: Equatable, Sendable {
    public enum Mode: String, Sendable {
        /// Caught from the browser: shows the catch panel unless the person said not to ask.
        case caught
        /// Chosen in the browser ("Download with Ladle", video button): starts right away.
        case direct
    }

    public var urls: [URL]
    public var referrer: URL?
    public var fileName: String?
    public var cookies: String?
    public var size: Int64?
    public var mimeType: String?
    public var checksum: ExpectedChecksum?
    public var source: String?
    public var mode: Mode
    /// For the video button: an HLS playlist and its details.
    public var kind: DownloadKind
    public var audioURL: URL?
    public var title: String?
    public var quality: String?
    public var bandwidth: Int?
    /// Proves the request came from Ladle's own extension (see `BrowserSettingsSnapshot.token`).
    public var token: String?

    public init(
        urls: [URL],
        referrer: URL? = nil,
        fileName: String? = nil,
        cookies: String? = nil,
        size: Int64? = nil,
        mimeType: String? = nil,
        checksum: ExpectedChecksum? = nil,
        source: String? = nil,
        mode: Mode = .caught,
        kind: DownloadKind = .file,
        audioURL: URL? = nil,
        title: String? = nil,
        quality: String? = nil,
        bandwidth: Int? = nil,
        token: String? = nil
    ) {
        self.urls = urls
        self.referrer = referrer
        self.fileName = fileName
        self.cookies = cookies
        self.size = size
        self.mimeType = mimeType
        self.checksum = checksum
        self.source = source
        self.mode = mode
        self.kind = kind
        self.audioURL = audioURL
        self.title = title
        self.quality = quality
        self.bandwidth = bandwidth
        self.token = token
    }

    /// More than one link opens the add sheet with the list.
    public var isBatch: Bool { urls.count > 1 }
}

/// `ladle://add?url=<percent-encoded>&referrer=…&filename=…&cookies=…`
/// Extra optional parameters: `url` repeated (a list), `size`, `mime`, `sha256`, `md5`, `source`,
/// `mode` (caught|direct), `kind` (file|hls), `audio`, `title`, `quality`, `bandwidth`, `token`.
public enum LadleURL {
    public static let scheme = "ladle"

    public static func parse(_ url: URL) -> HandOff? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        guard action == "add" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func first(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        let urls = items.filter { $0.name == "url" }.compactMap { $0.value }.compactMap(LinkParser.link(from:))
        guard !urls.isEmpty else { return nil }
        var checksum: ExpectedChecksum?
        if let sha = first("sha256") { checksum = ExpectedChecksum.parse("sha256:" + sha, source: .browser) }
        if checksum == nil, let md5 = first("md5") { checksum = ExpectedChecksum.parse("md5:" + md5, source: .browser) }
        return HandOff(
            urls: urls,
            referrer: first("referrer").flatMap(LinkParser.link(from:)),
            fileName: first("filename").map { FileNaming.sanitize($0) },
            cookies: first("cookies"),
            size: first("size").flatMap { Int64($0) }.flatMap { $0 > 0 ? $0 : nil },
            mimeType: first("mime"),
            checksum: checksum,
            source: first("source"),
            mode: first("mode").flatMap(HandOff.Mode.init(rawValue:)) ?? .caught,
            kind: first("kind").flatMap(DownloadKind.init(rawValue:)) ?? .file,
            audioURL: first("audio").flatMap(LinkParser.link(from:)),
            title: first("title"),
            quality: first("quality"),
            bandwidth: first("bandwidth").flatMap { Int($0) },
            token: first("token")
        )
    }

    public static func make(_ handOff: HandOff) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "add"
        var items: [URLQueryItem] = handOff.urls.map { URLQueryItem(name: "url", value: $0.absoluteString) }
        func add(_ name: String, _ value: String?) {
            if let value, !value.isEmpty { items.append(URLQueryItem(name: name, value: value)) }
        }
        add("referrer", handOff.referrer?.absoluteString)
        add("filename", handOff.fileName)
        add("cookies", handOff.cookies)
        add("size", handOff.size.map(String.init))
        add("mime", handOff.mimeType)
        if let sum = handOff.checksum { add(sum.algorithm.rawValue, sum.value) }
        add("source", handOff.source)
        if handOff.mode != .caught { add("mode", handOff.mode.rawValue) }
        if handOff.kind != .file { add("kind", handOff.kind.rawValue) }
        add("audio", handOff.audioURL?.absoluteString)
        add("title", handOff.title)
        add("quality", handOff.quality)
        add("bandwidth", handOff.bandwidth.map(String.init))
        add("token", handOff.token)
        components.queryItems = items
        // URLComponents leaves "+", "&" and "=" inside values alone in some cases; encode them strictly.
        components.percentEncodedQuery = items.map { item in
            "\(strict(item.name))=\(strict(item.value ?? ""))"
        }.joined(separator: "&")
        return components.url
    }

    private static func strict(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
