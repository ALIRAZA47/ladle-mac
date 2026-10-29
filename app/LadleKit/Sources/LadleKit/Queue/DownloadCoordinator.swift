import Foundation

/// Merges a video track and a separate audio track into one file (AVFoundation on the Mac).
public protocol MediaMuxer: Sendable {
    func merge(video: URL, audio: URL, into output: URL) async throws
}

/// Moves a replaced file out of the way (to the Trash on the Mac).
public protocol FileRecycler: Sendable {
    func recycle(_ url: URL) throws
}

public struct RemovingRecycler: FileRecycler {
    public init() {}
    public func recycle(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

public enum CoordinatorEvent: Sendable, Equatable {
    /// Finished, moved into place and (when possible) checked.
    case finished(DownloadItem)
    case failed(DownloadItem)
    /// Every Tonight download is done and nothing else is running.
    case tonightQueueFinished
}

public struct LiveInfo: Equatable, Sendable {
    public var speed: Double
    public var activeConnections: Int

    public init(speed: Double = 0, activeConnections: Int = 0) {
        self.speed = speed
        self.activeConnections = activeConnections
    }
}

public struct CoordinatorSnapshot: Sendable {
    public var items: [DownloadItem]
    public var live: [UUID: LiveInfo]
    public var totalSpeed: Double
    /// One sample a second, oldest first, for the sparkline.
    public var speedHistory: [Double]
    public var holds: Set<Hold>
    public var settings: Settings
    public var date: Date

    public init(items: [DownloadItem] = [], live: [UUID: LiveInfo] = [:], totalSpeed: Double = 0, speedHistory: [Double] = [], holds: Set<Hold> = [], settings: Settings = Settings(), date: Date = Date()) {
        self.items = items
        self.live = live
        self.totalSpeed = totalSpeed
        self.speedHistory = speedHistory
        self.holds = holds
        self.settings = settings
        self.date = date
    }
}

/// Owns the download list: adds, schedules, runs and saves downloads.
public actor DownloadCoordinator {
    public struct Environment: Sendable {
        public var transport: HTTPTransport
        public var clock: LadleClock
        public var calendar: Calendar
        public var home: URL
        public var muxer: MediaMuxer?
        public var recycler: FileRecycler
        /// Save to disk. Off in some tests.
        public var persists: Bool
        public var tickInterval: Double
        public var minPiece: Int64

        public init(
            transport: HTTPTransport,
            clock: LadleClock = SystemClock(),
            calendar: Calendar = .current,
            home: URL = FileManager.default.homeDirectoryForCurrentUser,
            muxer: MediaMuxer? = nil,
            recycler: FileRecycler = RemovingRecycler(),
            persists: Bool = true,
            tickInterval: Double = 0.5,
            minPiece: Int64 = PieceTable.defaultMinPiece
        ) {
            self.transport = transport
            self.clock = clock
            self.calendar = calendar
            self.home = home
            self.muxer = muxer
            self.recycler = recycler
            self.persists = persists
            self.tickInterval = tickInterval
            self.minPiece = minPiece
        }
    }

    private enum Engine {
        case file(FileDownloader)
        case hls(HLSDownloader)
    }

    private final class Runner {
        let engine: Engine
        var task: Task<Void, Never>?
        let startedUptime: Double
        /// What the item becomes once its task has stopped.
        var stopStatus: DownloadStatus = .queued
        var removeWhenStopped = false
        var startOverWhenStopped = false

        init(engine: Engine, startedUptime: Double) {
            self.engine = engine
            self.startedUptime = startedUptime
        }
    }

    public nonisolated let snapshots: AsyncStream<CoordinatorSnapshot>
    public nonisolated let events: AsyncStream<CoordinatorEvent>
    private let snapshotContinuation: AsyncStream<CoordinatorSnapshot>.Continuation
    private let eventContinuation: AsyncStream<CoordinatorEvent>.Continuation

    private let env: Environment
    private let store: JSONFileStore<DownloadsFile>
    private let limiter: TokenBucket
    private let throttle: HostThrottle

    private var items: [DownloadItem] = []
    private var settings: Settings
    private var holds: Set<Hold> = []
    private var runners: [UUID: Runner] = [:]
    private var live: [UUID: LiveInfo] = [:]
    private var history: [Double] = []
    private var ticker: Task<Void, Never>?
    private var tickCount = 0
    private var dirty = false
    private var tonightRan = false
    private var started = false
    /// Downloads whose bytes are in but which are still being merged into one file.
    private var finishing: Set<UUID> = []
    /// False once quitting starts, so stopping one download can't start another.
    private var acceptingWork = true

    public init(paths: AppPaths, settings: Settings, environment: Environment) {
        self.env = environment
        self.settings = settings.normalized()
        self.store = JSONFileStore(url: paths.downloads)
        self.limiter = TokenBucket(bytesPerSecond: settings.limitSpeed ? settings.speedLimitBytesPerSecond : nil, clock: environment.clock)
        self.throttle = HostThrottle(clock: environment.clock)
        var snapshotContinuation: AsyncStream<CoordinatorSnapshot>.Continuation!
        snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { snapshotContinuation = $0 }
        self.snapshotContinuation = snapshotContinuation
        var eventContinuation: AsyncStream<CoordinatorEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { eventContinuation = $0 }
        self.eventContinuation = eventContinuation
        history = [Double](repeating: 0, count: 48)
    }

    // MARK: - Lifecycle

    /// Loads the saved list and starts scheduling. Downloads that were running pick up again.
    public func start() {
        guard !started else { return }
        started = true
        if env.persists, let file = store.load() {
            items = file.items.map { saved in
                var item = saved
                if item.status == .downloading { item.status = .queued }
                if item.checksumState == .verifying { item.checksumState = nil }
                return item
            }
        }
        let interval = env.tickInterval
        let clock = env.clock
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(seconds: interval) } catch { return }
                await self?.tick()
            }
        }
        schedule()
        publish()
    }

    /// Stops every download (saving where each stopped) so they resume on the next launch.
    public func prepareForQuit() async {
        acceptingWork = false
        ticker?.cancel()
        ticker = nil
        let active = Array(runners.keys)
        for id in active { await stopRunner(id, becoming: .queued) }
        persist(force: true)
    }

    public func snapshot() -> CoordinatorSnapshot {
        CoordinatorSnapshot(items: items, live: live, totalSpeed: totalSpeed, speedHistory: history, holds: holds, settings: settings, date: env.clock.now())
    }

    public func item(_ id: UUID) -> DownloadItem? {
        items.first(where: { $0.id == id })
    }

    public var allItems: [DownloadItem] { items }

    // MARK: - Settings and holds

    public func update(settings newValue: Settings) {
        let normalized = newValue.normalized()
        let old = settings
        settings = normalized
        if old.limitSpeed != normalized.limitSpeed || old.speedLimitBytesPerSecond != normalized.speedLimitBytesPerSecond {
            limiter.setLimit(normalized.limitSpeed ? normalized.speedLimitBytesPerSecond : nil)
        }
        schedule()
        publish()
    }

    public func setHold(_ hold: Hold, active: Bool) async {
        let changed = active ? holds.insert(hold).inserted : holds.remove(hold) != nil
        guard changed else { return }
        if active {
            // Stop now, and wait, so progress is saved before the Mac sleeps.
            let plan = Scheduler.plan(items: items, settings: settings, holds: holds, now: env.clock.now(), calendar: env.calendar)
            for id in plan.stop { await stopRunner(id, becoming: .queued) }
            if hold == .sleeping {
                for id in Array(runners.keys) { await stopRunner(id, becoming: .queued) }
            }
            persist(force: true)
        }
        schedule()
        publish()
    }

    public var currentHolds: Set<Hold> { holds }

    // MARK: - Adding

    public func plan(_ requests: [DownloadRequest]) -> [AddPlan] {
        var reserved = Set<String>()
        return requests.map { request in
            let name = request.initialName
            let category = FileCategory.forFileName(name)
            let directory = request.directory ?? Destination.folder(for: category, settings: settings, home: env.home).path
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            let conflict = FileManager.default.fileExists(atPath: path) || reserved.contains(path)
            reserved.insert(path)
            let key = request.url.absoluteString
            return AddPlan(
                request: request,
                fileName: name,
                directory: directory,
                category: category,
                conflict: conflict,
                alreadyDownloaded: items.contains { $0.url.absoluteString == key && $0.status == .completed },
                alreadyInList: items.contains { $0.url.absoluteString == key && $0.status != .completed }
            )
        }
    }

    /// Adds planned downloads. `conflict` says what to do with names already in use (Keep both when nil).
    @discardableResult
    public func add(_ plans: [AddPlan], start: StartChoice = .now, conflict: ConflictChoice? = nil) -> [UUID] {
        let now = env.clock.now()
        var ids: [UUID] = []
        for plan in plans {
            let request = plan.request
            var name = plan.fileName
            let folder = URL(fileURLWithPath: plan.directory, isDirectory: true)
            let wantsReplace = (conflict ?? (settings.duplicatePolicy == .replace ? .replace : .keepBoth)) == .replace
            let onDisk = FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
            var replace = false
            if wantsReplace && onDisk && !isReservedByAnotherItem(name, in: plan.directory, except: nil) {
                replace = true
            } else {
                name = availableName(name, in: plan.directory, except: nil)
            }
            var item = DownloadItem(url: request.url, kind: request.kind, fileName: name, directory: plan.directory, queue: start == .tonight ? .tonight : .main, addedAt: now)
            item.referrer = request.referrer
            item.cookies = request.cookies
            item.userAgent = request.userAgent
            item.source = request.source
            item.nameIsFinal = request.fileName != nil || request.kind == .hls
            item.directoryIsFinal = request.directory != nil
            item.replaceExisting = replace
            item.totalBytes = request.size
            item.checksum = request.checksum
            item.connectionCount = settings.connectionsPerDownload
            if request.kind == .hls {
                var info = HLSInfo(playlistURL: request.url, audioPlaylistURL: request.audioURL, qualityLabel: request.quality, bandwidth: request.bandwidth)
                info.completedSegments = []
                item.hls = info
            }
            items.append(item)
            ids.append(item.id)
        }
        dirty = true
        persist(force: true)
        schedule()
        publish()
        return ids
    }

    /// Asks the server about a link (name, size, resumable) without downloading it.
    public func inspect(_ url: URL, referrer: URL? = nil, cookies: String? = nil, userAgent: String? = nil) async -> LinkInspection {
        var headers: [String: String] = [:]
        if let userAgent { headers["User-Agent"] = userAgent }
        let request = HTTPRequest(url: url, rangeStart: 0, rangeEnd: 0, cookies: cookies, referrer: referrer, headers: headers, connectionSlot: 31, timeout: 15)
        let fallbackName = FileNaming.suggestedName(url: url)
        do {
            let response = try await env.transport.open(request)
            response.body.cancel()
            let head = response.head
            switch ResponseClass.classify(status: head.statusCode) {
            case .ok:
                let name = FileNaming.suggestedName(
                    url: FileNaming.nameFromURL(head.url) != nil ? head.url : url,
                    contentDisposition: head.header("content-disposition"),
                    mimeType: head.header("content-type")
                )
                return LinkInspection(url: url, fileName: name, size: head.totalSize, resumable: head.statusCode == 206, mimeType: head.header("content-type"), failure: nil)
            case .fatal(let failure):
                return LinkInspection(url: url, fileName: fallbackName, size: nil, resumable: false, mimeType: nil, failure: failure)
            default:
                return LinkInspection(url: url, fileName: fallbackName, size: nil, resumable: false, mimeType: nil, failure: DownloadFailure(.serverError, httpStatus: head.statusCode))
            }
        } catch {
            return LinkInspection(url: url, fileName: fallbackName, size: nil, resumable: false, mimeType: nil, failure: FileDownloader.failure(from: error))
        }
    }

    // MARK: - Actions

    public func pause(_ id: UUID) async {
        guard let index = index(of: id) else { return }
        switch items[index].status {
        case .downloading:
            await stopRunner(id, becoming: .paused)
        case .queued:
            items[index].status = .paused
            items[index].manualStart = false
        default:
            return
        }
        dirty = true
        persist(force: true)
        schedule()
        publish()
    }

    /// Resumes a paused download right away, even past the queue limit.
    public func resume(_ id: UUID) {
        guard let index = index(of: id), items[index].status == .paused else { return }
        items[index].status = .queued
        items[index].manualStart = true
        dirty = true
        schedule()
        publish()
    }

    /// "Start now" on a queued download: runs it without waiting for a slot or for tonight.
    public func startNow(_ id: UUID) {
        guard let index = index(of: id), items[index].status == .queued || items[index].status == .paused else { return }
        items[index].status = .queued
        items[index].manualStart = true
        dirty = true
        schedule()
        publish()
    }

    public func retry(_ id: UUID) {
        guard let index = index(of: id), items[index].status == .failed else { return }
        if items[index].failure?.needsStartOver == true {
            Task { await self.startOver(id) }
            return
        }
        items[index].status = .queued
        items[index].manualStart = true
        items[index].failure = nil
        items[index].attempts = 0
        dirty = true
        schedule()
        publish()
    }

    /// Throws the partial file away and downloads again from the first byte.
    public func startOver(_ id: UUID) async {
        guard index(of: id) != nil, !finishing.contains(id) else { return }
        if let runner = runners[id] {
            // The finish handler does the reset, so nothing can restart it in between.
            runner.startOverWhenStopped = true
            runner.task?.cancel()
            await runner.task?.value
            return
        }
        resetForStartOver(id)
        persist(force: true)
        schedule()
        publish()
    }

    private func resetForStartOver(_ id: UUID) {
        guard let index = index(of: id) else { return }
        removePartial(items[index])
        items[index].resetProgress()
        items[index].status = .queued
        items[index].manualStart = true
        dirty = true
    }

    /// Removes it from the list. A finished file stays; an unfinished part file goes.
    public func remove(_ id: UUID) async {
        guard index(of: id) != nil, !finishing.contains(id) else { return }
        if let runner = runners[id] {
            runner.removeWhenStopped = true
            runner.task?.cancel()
            await runner.task?.value
            return
        }
        removeItem(id)
        persist(force: true)
        schedule()
        publish()
    }

    private func removeItem(_ id: UUID) {
        guard let index = index(of: id) else { return }
        let item = items.remove(at: index)
        if item.status != .completed { removePartial(item) }
        live[id] = nil
        dirty = true
    }

    public var hasActiveWork: Bool {
        items.contains { $0.status == .downloading || ($0.status == .queued && $0.queue == .main) }
    }

    /// Pauses everything that is downloading or waiting in line.
    public func pauseAll() async {
        // Waiting downloads first, so a stopping one can't hand its slot to them.
        for index in items.indices where items[index].status == .queued {
            items[index].status = .paused
            items[index].manualStart = false
        }
        for id in Array(runners.keys) {
            await stopRunner(id, becoming: .paused)
        }
        dirty = true
        persist(force: true)
        schedule()
        publish()
    }

    /// Puts paused downloads back in line; the queue limit applies.
    public func resumeAll() {
        for index in items.indices where items[index].status == .paused {
            items[index].status = .queued
            items[index].manualStart = false
        }
        dirty = true
        schedule()
        publish()
    }

    // MARK: - Running

    private func index(of id: UUID) -> Int? {
        items.firstIndex(where: { $0.id == id })
    }

    private var totalSpeed: Double {
        live.values.reduce(0) { $0 + $1.speed }
    }

    private func schedule() {
        guard acceptingWork else { return }
        let plan = Scheduler.plan(items: items, settings: settings, holds: holds, now: env.clock.now(), calendar: env.calendar)
        for id in plan.stop where !finishing.contains(id) {
            Task { await self.stopRunner(id, becoming: .queued) }
        }
        for id in plan.start where runners[id] == nil {
            launch(id)
        }
    }

    private func launch(_ id: UUID) {
        guard let index = index(of: id) else { return }
        var item = items[index]
        item.status = .downloading
        item.failure = nil
        item.attempts = 0
        if item.startedAt == nil { item.startedAt = env.clock.now() }
        item.connectionCount = item.kind == .hls ? settings.connectionsPerDownload : (item.resumable == false ? 1 : settings.connectionsPerDownload)
        items[index] = item
        if item.queue == .tonight { tonightRan = true }

        let engine: Engine
        switch item.kind {
        case .file:
            let job = FileJob(
                url: item.url,
                partURL: item.partURL,
                cookies: item.cookies,
                referrer: item.referrer,
                userAgent: item.userAgent,
                pieces: item.pieces,
                total: item.totalBytes,
                validator: item.validator,
                resumable: item.resumable,
                connections: settings.connectionsPerDownload,
                retryLimit: settings.retryLimit,
                minPiece: env.minPiece
            )
            let downloader = FileDownloader(job: job, transport: env.transport, limiter: limiter, throttle: throttle, clock: env.clock) { [weak self] info in
                guard let self else { throw CancellationError() }
                return try await self.prepareFile(id, info: info)
            }
            engine = .file(downloader)
        case .hls:
            let info = item.hls ?? HLSInfo(playlistURL: item.url)
            let job = HLSJob(
                playlistURL: info.playlistURL,
                partDirectory: item.partURL,
                audioPlaylistURL: info.audioPlaylistURL,
                qualityLabel: info.qualityLabel,
                cookies: item.cookies,
                referrer: item.referrer,
                userAgent: item.userAgent,
                completedSegments: info.completedSegments,
                segmentCount: info.segmentCount,
                connections: settings.connectionsPerDownload,
                retryLimit: settings.retryLimit
            )
            let downloader = HLSDownloader(job: job, transport: env.transport, limiter: limiter, throttle: throttle, clock: env.clock) { [weak self] plan in
                guard let self else { throw CancellationError() }
                return try await self.prepareHLS(id, plan: plan)
            }
            engine = .hls(downloader)
        }
        let runner = Runner(engine: engine, startedUptime: env.clock.uptime())
        runners[id] = runner
        live[id] = LiveInfo()
        runner.task = Task { [weak self] in
            switch engine {
            case .file(let downloader):
                let outcome = await downloader.run()
                await self?.fileFinished(id, outcome: outcome)
            case .hls(let downloader):
                let outcome = await downloader.run()
                await self?.hlsFinished(id, outcome: outcome)
            }
        }
        dirty = true
    }

    /// Stops a running download and waits until its progress is saved.
    private func stopRunner(_ id: UUID, becoming status: DownloadStatus) async {
        guard !finishing.contains(id) else { return }
        guard let runner = runners[id] else {
            if let index = index(of: id), items[index].status == .downloading {
                items[index].status = status
            }
            return
        }
        runner.stopStatus = status
        runner.task?.cancel()
        await runner.task?.value
    }

    /// Called by the file engine once the server has answered: settles name and folder.
    private func prepareFile(_ id: UUID, info: ProbeInfo) throws -> URL {
        guard let index = index(of: id) else { throw CancellationError() }
        var item = items[index]
        item.totalBytes = info.total
        item.resumable = info.resumable
        item.validator = info.validator
        if !info.resumable { item.connectionCount = 1 }
        if info.isFreshStart && !item.nameIsFinal {
            var better = info.suggestedName
            if better == nil, let fromFinal = FileNaming.nameFromURL(info.finalURL), !FileNaming.fileExtension(of: fromFinal).isEmpty {
                better = fromFinal
            }
            if better == nil, FileNaming.fileExtension(of: item.fileName).isEmpty, let mime = info.mimeType, let ext = FileNaming.fileExtension(forMIMEType: mime) {
                better = item.fileName + "." + ext
            }
            if let better, better != item.fileName {
                let category = FileCategory.forFileName(better)
                let directory = item.directoryIsFinal ? item.directory : Destination.folder(for: category, settings: settings, home: env.home).path
                item.fileName = availableName(better, in: directory, except: id)
                item.category = category
                item.directory = directory
            }
        }
        item.nameIsFinal = true
        items[index] = item
        dirty = true
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: item.directory, isDirectory: true), withIntermediateDirectories: true)
        return item.partURL
    }

    private func prepareHLS(_ id: UUID, plan: HLSPlanInfo) throws -> URL {
        guard let index = index(of: id) else { throw CancellationError() }
        var item = items[index]
        var info = item.hls ?? HLSInfo(playlistURL: item.url)
        info.container = plan.container
        if info.segmentCount != plan.segmentCount { info.completedSegments = [] }
        info.segmentCount = plan.segmentCount
        item.hls = info
        if item.totalBytes == nil, let estimate = plan.estimatedTotal { item.totalBytes = estimate }
        // The joined file's real type decides the extension (.mp4, .m4a or .ts).
        let (stem, ext) = FileNaming.splitExtension(item.fileName)
        if ext.dropFirst().lowercased() != plan.fileExtension && item.receivedBytes == 0 && info.completedSegments.isEmpty {
            item.fileName = availableName(stem + "." + plan.fileExtension, in: item.directory, except: id)
            item.category = FileCategory.forFileName(item.fileName)
        }
        item.resumable = true
        items[index] = item
        dirty = true
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: item.directory, isDirectory: true), withIntermediateDirectories: true)
        return item.partURL
    }

    private func endRun(_ id: UUID) -> (Runner?, Int?) {
        let runner = runners.removeValue(forKey: id)
        live[id] = nil
        guard let index = index(of: id) else { return (runner, nil) }
        if let runner {
            items[index].activeDuration += max(0, env.clock.uptime() - runner.startedUptime)
        }
        return (runner, index)
    }

    /// Applies "remove" or "start over" requested while the download was running.
    private func handledIntent(_ runner: Runner?, _ id: UUID) -> Bool {
        guard let runner else { return false }
        if runner.removeWhenStopped {
            removeItem(id)
        } else if runner.startOverWhenStopped {
            resetForStartOver(id)
        } else {
            return false
        }
        persist(force: true)
        schedule()
        publish()
        return true
    }

    private func fileFinished(_ id: UUID, outcome: DownloadOutcome) {
        let (runner, found) = endRun(id)
        if handledIntent(runner, id) { return }
        guard let index = found else { return }
        if case .file(let downloader) = runner?.engine {
            let progress = downloader.progress()
            if let pieces = downloader.checkpoint() { items[index].pieces = pieces }
            items[index].receivedBytes = progress.received
            if let total = progress.total { items[index].totalBytes = total }
            items[index].attempts = downloader.attempts
            if let resumable = progress.resumable { items[index].resumable = resumable }
            if let validator = progress.validator { items[index].validator = validator }
        }
        switch outcome {
        case .completed(let total):
            items[index].totalBytes = total
            items[index].receivedBytes = total
            items[index].pieces = [Piece(start: 0, end: total, received: total)]
            complete(index, joined: nil)
        case .failed(let failure):
            fail(index, failure)
        case .cancelled:
            items[index].status = runner?.stopStatus ?? .queued
            if items[index].status != .queued { items[index].manualStart = false }
        }
        dirty = true
        persist(force: true)
        schedule()
        publish()
    }

    private func hlsFinished(_ id: UUID, outcome: HLSOutcome) {
        let (runner, found) = endRun(id)
        if handledIntent(runner, id) { return }
        guard let index = found else { return }
        if case .hls(let downloader) = runner?.engine {
            let progress = downloader.progress()
            items[index].hls?.completedSegments = progress.completedSegments
            if let count = progress.segmentCount { items[index].hls?.segmentCount = count }
            items[index].receivedBytes = progress.bytes
            items[index].attempts = downloader.attempts
        }
        switch outcome {
        case .completed(let video, let audio, let plan):
            completeHLS(index, video: video, audio: audio, plan: plan)
        case .failed(let failure):
            fail(index, failure)
        case .cancelled:
            items[index].status = runner?.stopStatus ?? .queued
            if items[index].status != .queued { items[index].manualStart = false }
        }
        dirty = true
        persist(force: true)
        schedule()
        publish()
    }

    private func fail(_ index: Int, _ failure: DownloadFailure) {
        items[index].status = .failed
        items[index].failure = failure
        items[index].manualStart = false
        eventContinuation.yield(.failed(items[index]))
    }

    /// Moves the finished part file to its name, verifies the checksum, and announces it.
    private func complete(_ index: Int, joined: URL?) {
        var item = items[index]
        let source = joined ?? item.partURL
        do {
            let target = try placeFinishedFile(from: source, item: &item)
            item.fileName = target.lastPathComponent
        } catch {
            items[index] = item
            fail(index, (error as? DownloadFailure) ?? DownloadFailure(.writeFailed))
            return
        }
        item.status = .completed
        item.finishedAt = env.clock.now()
        item.manualStart = false
        item.failure = nil
        items[index] = item
        verifyAndAnnounce(item.id)
    }

    private func completeHLS(_ index: Int, video: URL, audio: URL?, plan: HLSPlanInfo) {
        let item = items[index]
        guard let audio else {
            complete(index, joined: video)
            removePartial(items[index])
            return
        }
        let id = item.id
        let muxer = env.muxer
        let canMerge = muxer != nil && plan.audioContainer.map { HLSJoin.canMergeSeparateAudio(video: plan.container, audio: $0) } == true
        items[index].status = .downloading
        finishing.insert(id)
        Task { [weak self] in
            var merged: URL?
            if canMerge, let muxer {
                let output = video.deletingLastPathComponent().appendingPathComponent("merged.\(plan.fileExtension)")
                do {
                    try await muxer.merge(video: video, audio: audio, into: output)
                    merged = output
                } catch {
                    merged = nil
                }
            }
            await self?.finishHLSMerge(id, video: video, audio: audio, merged: merged, plan: plan)
        }
    }

    private func finishHLSMerge(_ id: UUID, video: URL, audio: URL, merged: URL?, plan: HLSPlanInfo) {
        finishing.remove(id)
        guard let index = index(of: id) else { return }
        if let merged {
            complete(index, joined: merged)
        } else {
            // Couldn't merge: keep the audio as its own file next to the video.
            let item = items[index]
            let audioExt = plan.audioContainer.map { HLSJoin.fileExtension(container: $0, audioOnly: true) } ?? "m4a"
            let stem = FileNaming.splitExtension(item.fileName).stem
            let audioName = availableName("\(stem) (audio).\(audioExt)", in: item.directory, except: id)
            try? FileManager.default.moveItem(at: audio, to: URL(fileURLWithPath: item.directory).appendingPathComponent(audioName))
            complete(index, joined: video)
        }
        if let index = self.index(of: id) { removePartial(items[index]) }
        dirty = true
        persist(force: true)
        publish()
    }

    private func placeFinishedFile(from source: URL, item: inout DownloadItem) throws -> URL {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: item.directory, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appendingPathComponent(item.fileName)
        if fm.fileExists(atPath: target.path) {
            if item.replaceExisting || settings.duplicatePolicy == .replace {
                try env.recycler.recycle(target)
            } else {
                // A file with this name appeared while downloading: keep both.
                let name = availableName(item.fileName, in: item.directory, except: item.id)
                target = folder.appendingPathComponent(name)
            }
        }
        try fm.moveItem(at: source, to: target)
        return target
    }

    private func verifyAndAnnounce(_ id: UUID) {
        guard let index = index(of: id) else { return }
        let item = items[index]
        guard settings.verifyChecksums, item.kind == .file else {
            eventContinuation.yield(.finished(item))
            return
        }
        items[index].checksumState = .verifying
        let transport = env.transport
        Task.detached { [weak self] in
            var expected = item.checksum
            if expected == nil {
                expected = await DownloadCoordinator.fetchSidecar(for: item, transport: transport)
            }
            var state: ChecksumState?
            if let expected {
                if let matches = try? Checksums.verify(fileAt: item.finalURL, expected: expected) {
                    state = matches ? .verified : .mismatch
                }
            }
            await self?.checksumDone(id, state: state, expected: expected)
        }
    }

    private func checksumDone(_ id: UUID, state: ChecksumState?, expected: ExpectedChecksum?) {
        guard let index = index(of: id) else { return }
        items[index].checksumState = state
        if items[index].checksum == nil { items[index].checksum = expected }
        dirty = true
        persist(force: true)
        publish()
        eventContinuation.yield(.finished(items[index]))
    }

    /// `<file>.sha256` published next to the download, if the server has one.
    static func fetchSidecar(for item: DownloadItem, transport: HTTPTransport) async -> ExpectedChecksum? {
        guard var components = URLComponents(url: item.url, resolvingAgainstBaseURL: false) else { return nil }
        components.path += ".sha256"
        components.fragment = nil
        guard let sidecarURL = components.url else { return nil }
        var headers: [String: String] = [:]
        if let ua = item.userAgent { headers["User-Agent"] = ua }
        let request = HTTPRequest(url: sidecarURL, cookies: item.cookies, referrer: item.referrer, headers: headers, connectionSlot: 30, timeout: 10)
        guard let (head, data) = try? await transport.fetchAll(request, limit: 256 * 1024), head.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let name = FileNaming.nameFromURL(item.url) ?? item.fileName
        return Checksums.parseSidecar(text, fileName: name)
    }

    // MARK: - Names and files

    private func isReservedByAnotherItem(_ name: String, in directory: String, except id: UUID?) -> Bool {
        items.contains { other in
            other.id != id && other.status != .completed && other.directory == directory && other.fileName == name
        }
    }

    private func availableName(_ name: String, in directory: String, except id: UUID?) -> String {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        return FileNaming.availableName(for: name) { candidate in
            Destination.nameIsTaken(candidate, in: folder) || isReservedByAnotherItem(candidate, in: directory, except: id)
        }
    }

    private func removePartial(_ item: DownloadItem) {
        try? FileManager.default.removeItem(at: item.partURL)
    }

    // MARK: - Ticking

    private func tick() {
        tickCount += 1
        var changed = false
        for (id, runner) in runners {
            guard let index = index(of: id) else { continue }
            switch runner.engine {
            case .file(let downloader):
                let progress = downloader.progress()
                if items[index].receivedBytes != progress.received || items[index].totalBytes != progress.total {
                    items[index].receivedBytes = progress.received
                    if let total = progress.total { items[index].totalBytes = total }
                    changed = true
                }
                items[index].pieces = progress.pieces
                if let resumable = progress.resumable, items[index].resumable != resumable {
                    items[index].resumable = resumable
                    if !resumable { items[index].connectionCount = 1 }
                }
                live[id] = LiveInfo(speed: progress.speed, activeConnections: progress.activeConnections)
            case .hls(let downloader):
                let progress = downloader.progress()
                if items[index].receivedBytes != progress.bytes {
                    items[index].receivedBytes = progress.bytes
                    changed = true
                }
                items[index].hls?.completedSegments = progress.completedSegments
                if let count = progress.segmentCount { items[index].hls?.segmentCount = count }
                if items[index].totalBytes == nil, let estimate = progress.estimatedTotal { items[index].totalBytes = estimate }
                live[id] = LiveInfo(speed: progress.speed, activeConnections: progress.activeConnections)
            }
        }
        if changed { dirty = true }
        // Speed history: one sample a second.
        let ticksPerSecond = max(1, Int((1 / env.tickInterval).rounded()))
        if tickCount % ticksPerSecond == 0 {
            history.append(totalSpeed)
            if history.count > 48 { history.removeFirst(history.count - 48) }
        }
        // Resume state at least every 2 seconds.
        let ticksPerCheckpoint = max(1, Int((2 / env.tickInterval).rounded()))
        if tickCount % ticksPerCheckpoint == 0 {
            for (id, runner) in runners {
                guard case .file(let downloader) = runner.engine, let index = index(of: id) else { continue }
                if let pieces = downloader.checkpoint() { items[index].pieces = pieces }
            }
            persist(force: false)
        }
        schedule()
        checkTonightFinished()
        publish()
    }

    private func checkTonightFinished() {
        let open = TonightWindow(settings: settings).isActive(at: env.clock.now(), calendar: env.calendar)
        guard open else {
            tonightRan = false
            return
        }
        let tonightLeft = items.contains { $0.queue == .tonight && ($0.status == .queued || $0.status == .downloading) }
        if tonightRan && !tonightLeft && runners.isEmpty {
            tonightRan = false
            eventContinuation.yield(.tonightQueueFinished)
        }
    }

    private func persist(force: Bool) {
        guard env.persists, dirty || force else { return }
        do {
            try store.save(DownloadsFile(items: items))
            dirty = false
        } catch {
            // Keep the flag so the next tick tries again.
        }
    }

    private func publish() {
        snapshotContinuation.yield(snapshot())
    }
}
