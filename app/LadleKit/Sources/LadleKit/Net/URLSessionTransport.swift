import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `HTTPTransport` on URLSession. Each connection slot gets its own session so pieces travel on
/// separate TCP connections even when the server speaks HTTP/2. Bodies are pulled: when the reader
/// falls behind (for example under the speed limit) the task is suspended so TCP slows the server down.
public final class URLSessionTransport: NSObject, HTTPTransport, @unchecked Sendable {
    public static let poolSize = 32

    private let configuration: Locked<URLSessionConfiguration>
    private let userAgent: String
    private let sessions = Locked<[Int: URLSession]>([:])
    private let streams = Locked<[ObjectIdentifier: TransportStream]>([:])
    private let delegateQueue: OperationQueue

    public init(configuration: URLSessionConfiguration = URLSessionTransport.defaultConfiguration(), userAgent: String = "Ladle/1.0") {
        self.configuration = Locked(configuration)
        self.userAgent = userAgent
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Ladle transport"
        self.delegateQueue = queue
        super.init()
    }

    /// Ephemeral, no cookie store or cache (cookies come from the browser per download), many connections per host.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 32
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 7 * 24 * 3600
        return config
    }

    /// Uses `configuration` (for example a new proxy choice) for new connections. Transfers in
    /// progress finish on their old sessions.
    public func replaceConfiguration(_ configuration: URLSessionConfiguration) {
        self.configuration.withLock { $0 = configuration }
        let retired = sessions.withLock { (map: inout [Int: URLSession]) -> [URLSession] in
            let values = Array(map.values)
            map.removeAll()
            return values
        }
        for session in retired { session.finishTasksAndInvalidate() }
    }

    /// Cancels everything and releases the sessions (they keep their delegate alive until then).
    public func invalidate() {
        let all = sessions.withLock { (map: inout [Int: URLSession]) -> [URLSession] in
            let values = Array(map.values)
            map.removeAll()
            return values
        }
        for session in all { session.invalidateAndCancel() }
    }

    private func session(for slot: Int) -> URLSession {
        let key = abs(slot) % URLSessionTransport.poolSize
        return sessions.withLock { (map: inout [Int: URLSession]) -> URLSession in
            if let existing = map[key] { return existing }
            let created = URLSession(configuration: configuration.current, delegate: self, delegateQueue: delegateQueue)
            map[key] = created
            return created
        }
    }

    func urlRequest(for request: HTTPRequest, target: URL) -> URLRequest {
        var urlRequest = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false
        if request.headers["User-Agent"] == nil { urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        for (name, value) in request.headers(for: target) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    public func open(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw TransportError.badURL
        }
        try Task.checkCancellation()
        let task = session(for: request.connectionSlot).dataTask(with: urlRequest(for: request, target: request.url))
        let stream = TransportStream(request: request, task: task)
        streams.withLock { $0[ObjectIdentifier(task)] = stream }
        task.resume()
        let head = try await withTaskCancellationHandler {
            try await stream.response()
        } onCancel: {
            stream.cancel()
        }
        return HTTPResponse(head: head, body: stream)
    }

    fileprivate func stream(for task: URLSessionTask) -> TransportStream? {
        streams.withLock { $0[ObjectIdentifier(task)] }
    }

    fileprivate func forget(_ task: URLSessionTask) {
        streams.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(task)) }
    }

    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return TransportError.other(nsError.localizedDescription) }
        switch nsError.code {
        case NSURLErrorTimedOut: return TransportError.timedOut
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return TransportError.cannotFindHost
        case NSURLErrorCancelled: return CancellationError()
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return TransportError.badURL
        default: return TransportError.connectionLost
        }
    }
}

extension URLSessionTransport: URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let stream = stream(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        var headers: [String: String] = [:]
        var status = 200
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
        }
        stream.receive(HTTPResponseHead(statusCode: status, headers: headers, url: response.url ?? stream.request.url))
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stream(for: dataTask)?.append(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stream(for: task)?.finish(error.map(URLSessionTransport.map))
        forget(task)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let stream = stream(for: task), let target = request.url, stream.countRedirect() <= 10 else {
            completionHandler(nil)
            return
        }
        // Rebuild the headers for the new host: Range stays, cookies and referrer only for the original host.
        completionHandler(urlRequest(for: stream.request, target: target))
    }
}

/// One response: its head, then body chunks in order, buffered with a high/low water mark.
/// The suspended flag and the task's real state change together under the lock.
final class TransportStream: HTTPBody, @unchecked Sendable {
    let request: HTTPRequest
    private let task: URLSessionDataTask
    private let lock = NSLock()
    private var head: HTTPResponseHead?
    private var headWaiter: CheckedContinuation<HTTPResponseHead, Error>?
    private var chunks: [Data] = []
    private var buffered = 0
    private var finished = false
    private var finalError: Error?
    private var chunkWaiter: CheckedContinuation<Data?, Error>?
    private var suspended = false
    private var redirects = 0

    static let highWater = 512 * 1024
    static let lowWater = 128 * 1024

    init(request: HTTPRequest, task: URLSessionDataTask) {
        self.request = request
        self.task = task
    }

    func countRedirect() -> Int {
        lock.lock()
        defer { lock.unlock() }
        redirects += 1
        return redirects
    }

    func response() async throws -> HTTPResponseHead {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponseHead, Error>) in
            lock.lock()
            if let head {
                lock.unlock()
                continuation.resume(returning: head)
            } else if finished {
                let error = finalError ?? TransportError.connectionLost
                lock.unlock()
                continuation.resume(throwing: error)
            } else {
                headWaiter = continuation
                lock.unlock()
            }
        }
    }

    func receive(_ newHead: HTTPResponseHead) {
        lock.lock()
        guard head == nil else {
            lock.unlock()
            return
        }
        head = newHead
        let waiter = headWaiter
        headWaiter = nil
        lock.unlock()
        waiter?.resume(returning: newHead)
    }

    func append(_ data: Data) {
        lock.lock()
        if let waiter = chunkWaiter {
            chunkWaiter = nil
            lock.unlock()
            waiter.resume(returning: data)
            return
        }
        chunks.append(data)
        buffered += data.count
        if buffered > TransportStream.highWater && !suspended && !finished {
            suspended = true
            task.suspend()
        }
        lock.unlock()
    }

    func finish(_ error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        finalError = error
        let headWaiter = self.headWaiter
        self.headWaiter = nil
        let chunkWaiter = self.chunkWaiter
        self.chunkWaiter = nil
        let hasHead = head != nil
        lock.unlock()
        if let headWaiter, !hasHead {
            headWaiter.resume(throwing: error ?? TransportError.connectionLost)
        }
        if let chunkWaiter {
            if let error { chunkWaiter.resume(throwing: error) } else { chunkWaiter.resume(returning: nil) }
        }
    }

    func next() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                lock.lock()
                if !chunks.isEmpty {
                    let chunk = chunks.removeFirst()
                    buffered -= chunk.count
                    if suspended && buffered < TransportStream.lowWater {
                        suspended = false
                        task.resume()
                    }
                    lock.unlock()
                    continuation.resume(returning: chunk)
                } else if finished {
                    let error = finalError
                    lock.unlock()
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: nil) }
                } else {
                    // An empty buffer is always below the low water mark, so the task is running.
                    chunkWaiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        task.cancel()
        finish(CancellationError())
    }
}
