import Foundation

public struct HLSJob: Sendable {
    /// A media playlist, or a master playlist (then `qualityLabel` picks the variant, else the best).
    public var playlistURL: URL
    public var audioPlaylistURL: URL?
    public var qualityLabel: String?
    public var cookies: String?
    public var referrer: URL?
    public var userAgent: String?
    /// The `.ladle-part` folder the segments go into.
    public var partDirectory: URL
    public var completedSegments: [Int]
    public var segmentCount: Int?
    public var connections: Int
    public var retryLimit: Int

    public init(
        playlistURL: URL,
        partDirectory: URL,
        audioPlaylistURL: URL? = nil,
        qualityLabel: String? = nil,
        cookies: String? = nil,
        referrer: URL? = nil,
        userAgent: String? = nil,
        completedSegments: [Int] = [],
        segmentCount: Int? = nil,
        connections: Int = 8,
        retryLimit: Int = 3
    ) {
        self.playlistURL = playlistURL
        self.partDirectory = partDirectory
        self.audioPlaylistURL = audioPlaylistURL
        self.qualityLabel = qualityLabel
        self.cookies = cookies
        self.referrer = referrer
        self.userAgent = userAgent
        self.completedSegments = completedSegments
        self.segmentCount = segmentCount
        self.connections = max(1, connections)
        self.retryLimit = retryLimit
    }
}

/// What the playlists turned out to be, before any segment is fetched.
public struct HLSPlanInfo: Sendable, Equatable {
    public var container: HLSInfo.Container
    public var audioContainer: HLSInfo.Container?
    public var segmentCount: Int
    public var duration: Double
    public var isAudioOnly: Bool
    public var fileExtension: String
    public var estimatedTotal: Int64?
}

public enum HLSOutcome: Sendable, Equatable {
    /// Joined files inside the part folder, ready to be moved (and merged, when there's separate audio).
    case completed(video: URL, audio: URL?, plan: HLSPlanInfo)
    case failed(DownloadFailure)
    case cancelled
}

public struct HLSProgress: Sendable, Equatable {
    public var completedSegments: [Int]
    public var segmentCount: Int?
    public var bytes: Int64
    public var estimatedTotal: Int64?
    public var activeConnections: Int
    public var speed: Double
}

/// Saves an unencrypted, finished HLS stream: fetches the playlists, downloads the segments over
/// several connections into the part folder, then joins them in order.
public final class HLSDownloader: @unchecked Sendable {
    public typealias Prepare = @Sendable (HLSPlanInfo) async throws -> URL

    struct Entry: Sendable {
        var url: URL
        var range: HLSByteRange?
    }

    private let job: HLSJob
    private let transport: HTTPTransport
    private let limiter: TokenBucket
    private let throttle: HostThrottle
    private let clock: LadleClock
    private let prepare: Prepare
    private let policy: RetryPolicy
    private let meter = SpeedMeter()
    private let host: String
    /// Segments bigger than this are not plausible and are refused.
    static let segmentLimit = 512 << 20

    private struct State {
        var completed: Set<Int> = []
        var count: Int?
        var bytes: Int64 = 0
        var active = 0
        var estimatedTotal: Int64?
        var mostFailures = 0
    }

    private let state = Locked(State())

    public init(job: HLSJob, transport: HTTPTransport, limiter: TokenBucket, throttle: HostThrottle, clock: LadleClock = SystemClock(), prepare: @escaping Prepare) {
        self.job = job
        self.transport = transport
        self.limiter = limiter
        self.throttle = throttle
        self.clock = clock
        self.prepare = prepare
        self.policy = RetryPolicy(limit: job.retryLimit)
        self.host = job.playlistURL.host ?? ""
    }

    public var attempts: Int { state.current.mostFailures }

    public func progress() -> HLSProgress {
        let s = state.current
        return HLSProgress(
            completedSegments: s.completed.sorted(),
            segmentCount: s.count,
            bytes: s.bytes,
            estimatedTotal: s.estimatedTotal,
            activeConnections: s.active,
            speed: meter.rate(at: clock.uptime())
        )
    }

    public func run() async -> HLSOutcome {
        do {
            return try await runInner()
        } catch {
            if error is CancellationError || Task.isCancelled { return .cancelled }
            if let failure = error as? DownloadFailure { return .failed(failure) }
            if let transportError = error as? TransportError { return .failed(transportError.failure) }
            return .failed(DownloadFailure(.network))
        }
    }

    private func request(_ url: URL, range: HLSByteRange? = nil, slot: Int = 0) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let ua = job.userAgent, !ua.isEmpty { headers["User-Agent"] = ua }
        // Cookies belong to the playlist's origin; keep them for requests to that origin only. The
        // referrer shrinks to its origin on other hosts (HTTPRequest.headers(for:)).
        let sameOrigin = RedirectPolicy.isSameOrigin(url, job.playlistURL)
        return HTTPRequest(
            url: url,
            rangeStart: range?.offset,
            rangeEnd: range?.lastByte,
            cookies: sameOrigin ? job.cookies : nil,
            referrer: job.referrer,
            headers: headers,
            connectionSlot: slot
        )
    }

    private func withRetries<T>(_ body: () async throws -> T) async throws -> T {
        var failures = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await body()
            } catch let error as CancellationError {
                throw error
            } catch {
                let failure = FileDownloader.failure(from: error)
                failures += 1
                state.withLock { $0.mostFailures = max($0.mostFailures, failures) }
                guard failure.isRetryable, policy.allowsRetry(afterFailures: failures) else { throw failure }
                try await clock.sleep(seconds: policy.delay(forAttempt: failures))
            }
        }
    }

    private func fetchText(_ url: URL) async throws -> String {
        try await withRetries {
            let (head, data) = try await transport.fetchAll(request(url), limit: 16 << 20)
            switch ResponseClass.classify(status: head.statusCode) {
            case .ok: break
            case .fatal(let failure): throw failure
            default: throw DownloadFailure(.serverError, httpStatus: head.statusCode)
            }
            guard let text = String(data: data, encoding: .utf8) else { throw DownloadFailure(.invalidResponse) }
            return text
        }
    }

    private func mediaPlaylist(at url: URL) async throws -> (HLSMediaPlaylist, URL?) {
        let text = try await fetchText(url)
        let parsed: HLSPlaylist
        do { parsed = try M3U8.parse(text, baseURL: url) } catch { throw DownloadFailure(.invalidResponse) }
        switch parsed {
        case .media(let media):
            return (media, nil)
        case .master(let master):
            if master.isProtected { throw DownloadFailure(.protectedVideo) }
            let variants = master.sortedVariants
            let chosen = variants.first(where: { $0.qualityLabel == job.qualityLabel }) ?? variants.first(where: { !$0.isAudioOnly }) ?? variants.first
            guard let variant = chosen else { throw DownloadFailure(.invalidResponse) }
            let audio = master.audioRendition(for: variant)?.uri
            let (media, _) = try await mediaPlaylist(at: variant.uri)
            state.withLock { s in
                if s.estimatedTotal == nil {
                    s.estimatedTotal = HLSJoin.estimatedSize(bandwidth: variant.averageBandwidth ?? variant.bandwidth, duration: media.totalDuration)
                }
            }
            return (media, audio)
        }
    }

    private static func entries(for playlist: HLSMediaPlaylist) -> [Entry] {
        var list: [Entry] = []
        if let map = playlist.map { list.append(Entry(url: map.uri, range: map.byteRange)) }
        list.append(contentsOf: playlist.segments.map { Entry(url: $0.uri, range: $0.byteRange) })
        return list
    }

    private func runInner() async throws -> HLSOutcome {
        let (video, discoveredAudio) = try await mediaPlaylist(at: job.playlistURL)
        if video.isProtected { throw DownloadFailure(.protectedVideo) }
        guard video.isComplete else { throw DownloadFailure(.liveStream) }
        guard !video.segments.isEmpty else { throw DownloadFailure(.invalidResponse) }
        var audio: HLSMediaPlaylist?
        if let audioURL = job.audioPlaylistURL ?? discoveredAudio {
            let (playlist, _) = try await mediaPlaylist(at: audioURL)
            if playlist.isProtected { throw DownloadFailure(.protectedVideo) }
            guard playlist.isComplete else { throw DownloadFailure(.liveStream) }
            audio = playlist
        }
        let videoEntries = HLSDownloader.entries(for: video)
        let audioEntries = audio.map(HLSDownloader.entries(for:)) ?? []
        let all = videoEntries + audioEntries
        let container = HLSJoin.container(for: video)
        let audioContainer = audio.map(HLSJoin.container(for:))
        let isAudioOnly = job.qualityLabel == "Audio only"
        let segmentExt = FileNaming.fileExtension(of: video.segments[0].uri.path)
        let plan = HLSPlanInfo(
            container: container,
            audioContainer: audioContainer,
            segmentCount: all.count,
            duration: video.totalDuration,
            isAudioOnly: isAudioOnly,
            fileExtension: HLSJoin.fileExtension(container: container, audioOnly: isAudioOnly, segmentExtension: segmentExt),
            estimatedTotal: state.current.estimatedTotal
        )
        let directory = try await prepare(plan)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Keep finished segments only if the playlist is the same shape as last time.
        var done = Set<Int>()
        if job.segmentCount == all.count {
            for index in job.completedSegments where FileManager.default.fileExists(atPath: segmentURL(index, in: directory).path) {
                done.insert(index)
            }
        }
        var bytes: Int64 = 0
        for index in done {
            bytes += (try? FileManager.default.attributesOfItem(atPath: segmentURL(index, in: directory).path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        state.withLock { s in
            s.completed = done
            s.count = all.count
            s.bytes = bytes
        }

        let pending = Locked((0..<all.count).filter { !done.contains($0) })
        let workers = min(job.connections, max(1, pending.current.count))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for slot in 0..<workers {
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        let cap = self.throttle.allowedConnections(host: self.host, wanted: self.job.connections)
                        if slot >= cap {
                            try await self.clock.sleep(seconds: 1)
                            if pending.current.isEmpty { return }
                            continue
                        }
                        guard let index = pending.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { return }
                        do {
                            try await self.fetchSegment(index, entry: all[index], directory: directory, slot: slot)
                        } catch {
                            if !(error is CancellationError) { pending.withLock { $0.insert(index, at: 0) } }
                            throw error
                        }
                    }
                }
            }
            for try await _ in group {}
        }

        let videoFile = directory.appendingPathComponent("joined-video")
        try join(range: 0..<videoEntries.count, in: directory, to: videoFile)
        var audioFile: URL?
        if !audioEntries.isEmpty {
            let file = directory.appendingPathComponent("joined-audio")
            try join(range: videoEntries.count..<all.count, in: directory, to: file)
            audioFile = file
        }
        return .completed(video: videoFile, audio: audioFile, plan: plan)
    }

    func segmentURL(_ index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "%06d.seg", index))
    }

    private func fetchSegment(_ index: Int, entry: Entry, directory: URL, slot: Int) async throws {
        state.withLock { $0.active += 1 }
        defer { state.withLock { $0.active -= 1 } }
        let target = segmentURL(index, in: directory)
        let temporary = directory.appendingPathComponent(String(format: "%06d.tmp", index))
        try await withRetries {
            let wait = throttle.waitTime(host: host)
            if wait > 0 { try await clock.sleep(seconds: wait) }
            let response = try await transport.open(request(entry.url, range: entry.range, slot: slot))
            let head = response.head
            switch ResponseClass.classify(status: head.statusCode) {
            case .ok:
                break
            case .slowDown:
                response.body.cancel()
                let after = RetryAfter.seconds(from: head.header("retry-after"), now: clock.now())
                throttle.pushedBack(host: host, currentConnections: job.connections, retryAfter: after)
                throw DownloadFailure(.serverError, httpStatus: head.statusCode)
            case .fatal(let failure):
                response.body.cancel()
                throw failure
            default:
                response.body.cancel()
                throw DownloadFailure(.serverError, httpStatus: head.statusCode)
            }
            if entry.range != nil && head.statusCode != 206 {
                response.body.cancel()
                throw DownloadFailure(.invalidResponse, httpStatus: head.statusCode)
            }
            _ = FileManager.default.createFile(atPath: temporary.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temporary)
            var written = 0
            do {
                while let chunk = try await response.body.next() {
                    try await limiter.consume(chunk.count)
                    written += chunk.count
                    if written > HLSDownloader.segmentLimit { throw DownloadFailure(.invalidResponse) }
                    try handle.write(contentsOf: chunk)
                    meter.record(chunk.count, at: clock.uptime())
                }
                try handle.close()
            } catch {
                response.body.cancel()
                try? handle.close()
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            if let range = entry.range, Int64(written) != range.length {
                try? FileManager.default.removeItem(at: temporary)
                throw TransportError.connectionLost
            }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
            state.withLock { s in
                s.completed.insert(index)
                s.bytes += Int64(written)
            }
        }
    }

    private func join(range: Range<Int>, in directory: URL, to output: URL) throws {
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        for index in range {
            let input = try FileHandle(forReadingFrom: segmentURL(index, in: directory))
            defer { try? input.close() }
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                try out.write(contentsOf: chunk)
            }
        }
        try out.synchronize()
    }
}
