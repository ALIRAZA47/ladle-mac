import Foundation

/// A GET Ladle wants to make. Cookies and referrer are kept apart from other headers so the
/// transport can drop them when a redirect leaves the download's own host.
public struct HTTPRequest: Sendable {
    public var url: URL
    /// First byte, and optionally the last byte (inclusive).
    public var rangeStart: Int64?
    public var rangeEnd: Int64?
    public var cookies: String?
    public var referrer: URL?
    public var headers: [String: String]
    /// Spreads connections over separate sessions so each piece gets its own TCP connection.
    public var connectionSlot: Int
    public var timeout: Double

    public init(
        url: URL,
        rangeStart: Int64? = nil,
        rangeEnd: Int64? = nil,
        cookies: String? = nil,
        referrer: URL? = nil,
        headers: [String: String] = [:],
        connectionSlot: Int = 0,
        timeout: Double = 30
    ) {
        self.url = url
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.cookies = cookies
        self.referrer = referrer
        self.headers = headers
        self.connectionSlot = connectionSlot
        self.timeout = timeout
    }

    public var rangeHeader: String? {
        guard let start = rangeStart else { return nil }
        if let end = rangeEnd { return "bytes=\(start)-\(end)" }
        return "bytes=\(start)-"
    }

    /// Headers to send to `target`: cookies and referrer only when `target` is the request's own host.
    public func headers(for target: URL) -> [String: String] {
        var result = headers
        result["Accept-Encoding"] = "identity"
        if let range = rangeHeader { result["Range"] = range }
        if RedirectPolicy.isSameHost(url, target) {
            if let cookies, !cookies.isEmpty { result["Cookie"] = cookies }
            if let referrer { result["Referer"] = referrer.absoluteString }
        }
        return result
    }
}

public struct HTTPResponseHead: Sendable {
    public var statusCode: Int
    /// Lowercased names.
    public var headers: [String: String]
    /// After redirects.
    public var url: URL

    public init(statusCode: Int, headers: [String: String], url: URL) {
        self.statusCode = statusCode
        var lowered: [String: String] = [:]
        for (key, value) in headers { lowered[key.lowercased()] = value }
        self.headers = lowered
        self.url = url
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var contentLength: Int64? {
        header("content-length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    public var contentRange: ContentRange? {
        header("content-range").flatMap(ContentRange.parse)
    }

    public var validator: Validator {
        Validator(etag: header("etag"), lastModified: header("last-modified"), size: totalSize)
    }

    /// Size of the whole file: from Content-Range on a 206, Content-Length on a 200.
    public var totalSize: Int64? {
        if statusCode == 206 { return contentRange?.total }
        if statusCode == 200 { return contentLength }
        return nil
    }
}

/// The body of a response, read a chunk at a time. Reading slowly makes the connection slow down.
public protocol HTTPBody: AnyObject, Sendable {
    /// The next chunk, or nil at the end.
    func next() async throws -> Data?
    func cancel()
}

public struct HTTPResponse: Sendable {
    public var head: HTTPResponseHead
    public var body: HTTPBody

    public init(head: HTTPResponseHead, body: HTTPBody) {
        self.head = head
        self.body = body
    }
}

/// Network access for the engine. The app uses `URLSessionTransport`; tests use fakes.
public protocol HTTPTransport: Sendable {
    func open(_ request: HTTPRequest) async throws -> HTTPResponse
}

public extension HTTPTransport {
    /// Fetches a small resource (a playlist, a checksum file) completely.
    func fetchAll(_ request: HTTPRequest, limit: Int = 8 << 20) async throws -> (HTTPResponseHead, Data) {
        let response = try await open(request)
        var data = Data()
        do {
            while let chunk = try await response.body.next() {
                data.append(chunk)
                if data.count > limit {
                    response.body.cancel()
                    throw DownloadFailure(.invalidResponse)
                }
            }
        } catch {
            response.body.cancel()
            throw error
        }
        return (response.head, data)
    }
}

/// Errors from the transport, mapped to what Ladle tells people.
public enum TransportError: Error, Equatable, Sendable {
    case timedOut
    case cannotFindHost
    case connectionLost
    case cancelled
    case badURL
    case other(String)

    public var failure: DownloadFailure {
        switch self {
        case .timedOut: return DownloadFailure(.timedOut)
        case .cannotFindHost: return DownloadFailure(.cannotFindHost)
        case .connectionLost, .other: return DownloadFailure(.network)
        case .cancelled: return DownloadFailure(.network)
        case .badURL: return DownloadFailure(.unsupportedLink)
        }
    }
}
