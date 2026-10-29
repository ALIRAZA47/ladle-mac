import Foundation

public enum DownloadStatus: String, Codable, Sendable {
    /// Wants to run: waiting for a free slot, the Tonight window, or a hold to clear.
    case queued
    case downloading
    /// Paused by the person. Never starts on its own.
    case paused
    case failed
    case completed
}

public enum QueueKind: String, Codable, Sendable {
    case main, tonight
}

public enum DownloadKind: String, Codable, Sendable {
    case file, hls
}

/// One byte range of the file. `end` is exclusive; `received` counts bytes written from `start`.
public struct Piece: Codable, Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    public var received: Int64

    public init(start: Int64, end: Int64, received: Int64 = 0) {
        self.start = start
        self.end = end
        self.received = received
    }

    public var length: Int64 { end - start }
    public var remaining: Int64 { max(0, length - received) }
    public var isComplete: Bool { received >= length }
    /// The next byte this piece needs.
    public var position: Int64 { start + received }
}

/// What identifies the exact file on the server, so a resume never mixes two versions.
public struct Validator: Codable, Equatable, Sendable {
    public var etag: String?
    public var lastModified: String?
    public var size: Int64?

    public init(etag: String? = nil, lastModified: String? = nil, size: Int64? = nil) {
        self.etag = etag
        self.lastModified = lastModified
        self.size = size
    }

    /// ETag when both sides have one, else Last-Modified, and the size always when known.
    public func matches(_ other: Validator) -> Bool {
        if let a = size, let b = other.size, a != b { return false }
        if let a = etag, let b = other.etag { return a == b }
        if let a = lastModified, let b = other.lastModified { return a == b }
        return true
    }

    public var isEmpty: Bool { etag == nil && lastModified == nil && size == nil }
}

public enum ChecksumAlgorithm: String, Codable, Sendable {
    case sha256, md5

    public var title: String {
        switch self {
        case .sha256: return "SHA-256"
        case .md5: return "MD5"
        }
    }

    public var hexLength: Int {
        switch self {
        case .sha256: return 64
        case .md5: return 32
        }
    }
}

public struct ExpectedChecksum: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case pasted, browser, sidecar
    }

    public var algorithm: ChecksumAlgorithm
    /// Lowercase hex.
    public var value: String
    public var source: Source

    public init(algorithm: ChecksumAlgorithm, value: String, source: Source) {
        self.algorithm = algorithm
        self.value = value.lowercased()
        self.source = source
    }

    /// Accepts a bare hex digest of the right length, or `sha256:…` / `md5:…`.
    public static func parse(_ token: String, source: Source) -> ExpectedChecksum? {
        var text = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var forced: ChecksumAlgorithm?
        let lower = text.lowercased()
        for (prefix, algorithm) in [("sha256:", ChecksumAlgorithm.sha256), ("sha-256:", .sha256), ("md5:", .md5)] where lower.hasPrefix(prefix) {
            forced = algorithm
            text = String(text.dropFirst(prefix.count))
        }
        guard !text.isEmpty, text.allSatisfy({ $0.isHexDigit }) else { return nil }
        let algorithm: ChecksumAlgorithm
        switch text.count {
        case 64: algorithm = .sha256
        case 32: algorithm = .md5
        default: return nil
        }
        if let forced, forced != algorithm { return nil }
        return ExpectedChecksum(algorithm: algorithm, value: text, source: source)
    }
}

public enum ChecksumState: String, Codable, Sendable {
    case verifying, verified, mismatch
}

public struct DownloadFailure: Codable, Equatable, Sendable, Error {
    public enum Code: String, Codable, Sendable {
        case network
        case timedOut
        case cannotFindHost
        case notFound
        case forbidden
        case serverError
        case invalidResponse
        case changedOnServer
        case cannotResume
        case diskFull
        case writeFailed
        case protectedVideo
        case liveStream
        case unsupportedLink
    }

    public var code: Code
    public var httpStatus: Int?

    public init(_ code: Code, httpStatus: Int? = nil) {
        self.code = code
        self.httpStatus = httpStatus
    }

    /// Whether the only way forward is to start the file over (asked first, never automatic).
    public var needsStartOver: Bool {
        code == .changedOnServer || code == .cannotResume
    }

    /// Whether trying again later can help.
    public var isRetryable: Bool {
        switch code {
        case .network, .timedOut, .serverError, .invalidResponse, .cannotFindHost: return true
        default: return false
        }
    }

    /// One sentence, no trailing period. Shown in the details panel and, lowercased, in the row.
    public var message: String {
        switch code {
        case .network: return "The connection was lost"
        case .timedOut: return "The server stopped responding"
        case .cannotFindHost: return "Couldn’t find the server"
        case .notFound: return "The file isn’t on the server anymore"
        case .forbidden: return "The server refused the download"
        case .serverError:
            if let httpStatus { return "The server had a problem (error \(httpStatus))" }
            return "The server had a problem"
        case .invalidResponse: return "The server sent something unexpected"
        case .changedOnServer: return "The file changed on the server"
        case .cannotResume: return "This server can’t resume downloads"
        case .diskFull: return "There isn’t enough space on the disk"
        case .writeFailed: return "Ladle couldn’t write the file"
        case .protectedVideo: return "Protected video can’t be saved"
        case .liveStream: return "Live streams can’t be saved"
        case .unsupportedLink: return "That link can’t be downloaded"
        }
    }
}

public struct HLSInfo: Codable, Equatable, Sendable {
    public enum Container: String, Codable, Sendable {
        case fragmentedMP4, transportStream, packedAudio
    }

    /// The media playlist to download (a master playlist is resolved on first run).
    public var playlistURL: URL
    /// A separate audio rendition, when the variant has no audio of its own.
    public var audioPlaylistURL: URL?
    public var qualityLabel: String?
    public var bandwidth: Int?
    public var container: Container?
    public var segmentCount: Int?
    /// Indexes into the joined segment list (video first, then audio) that are on disk.
    public var completedSegments: [Int] = []

    public init(playlistURL: URL, audioPlaylistURL: URL? = nil, qualityLabel: String? = nil, bandwidth: Int? = nil) {
        self.playlistURL = playlistURL
        self.audioPlaylistURL = audioPlaylistURL
        self.qualityLabel = qualityLabel
        self.bandwidth = bandwidth
    }
}

/// A download as stored in Application Support and shown in the list.
public struct DownloadItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: URL
    public var kind: DownloadKind
    public var hls: HLSInfo?
    public var referrer: URL?
    /// Cookie header from the browser. Sent only to `url`'s host.
    public var cookies: String?
    /// The browser's user agent, so sites that tie cookies to it keep working.
    public var userAgent: String?
    /// Where it came from, for the catch panel and details: "Safari", "Clipboard"…
    public var source: String?

    /// The name it will have when finished, already free of conflicts.
    public var fileName: String
    /// True when the name came from the person, the browser or the server, so a probe must not change it.
    public var nameIsFinal: Bool
    /// Absolute folder path.
    public var directory: String
    /// The folder was picked by hand, so a better name from the server doesn't move the file.
    public var directoryIsFinal: Bool
    /// The person chose "Replace" for an existing file with this name.
    public var replaceExisting: Bool
    public var category: FileCategory
    public var queue: QueueKind
    public var status: DownloadStatus
    /// Started by hand ("Start now", "Resume", "Retry"): runs even past the queue limit.
    public var manualStart: Bool

    public var totalBytes: Int64?
    public var receivedBytes: Int64
    public var pieces: [Piece]
    public var validator: Validator?
    /// `nil` until the server has answered a range probe.
    public var resumable: Bool?
    /// How many connections the progress bar shows.
    public var connectionCount: Int

    public var addedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Seconds spent actually downloading, for "84.6 MB in 7 seconds".
    public var activeDuration: Double
    /// Retries used in the current run, shown as "Tried 3 times".
    public var attempts: Int
    public var failure: DownloadFailure?
    public var checksum: ExpectedChecksum?
    public var checksumState: ChecksumState?

    public init(
        id: UUID = UUID(),
        url: URL,
        kind: DownloadKind = .file,
        fileName: String,
        directory: String,
        queue: QueueKind = .main,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.hls = nil
        self.referrer = nil
        self.cookies = nil
        self.userAgent = nil
        self.source = nil
        self.fileName = fileName
        self.nameIsFinal = false
        self.directory = directory
        self.directoryIsFinal = false
        self.replaceExisting = false
        self.category = FileCategory.forFileName(fileName)
        self.queue = queue
        self.status = .queued
        self.manualStart = false
        self.totalBytes = nil
        self.receivedBytes = 0
        self.pieces = []
        self.validator = nil
        self.resumable = nil
        self.connectionCount = 1
        self.addedAt = addedAt
        self.startedAt = nil
        self.finishedAt = nil
        self.activeDuration = 0
        self.attempts = 0
        self.failure = nil
        self.checksum = nil
        self.checksumState = nil
    }

    public var host: String { url.host ?? "" }

    public var fileExtension: String { FileNaming.fileExtension(of: fileName) }

    public var finalURL: URL {
        URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(fileName)
    }

    /// `<name>.ladle-part`: a file for normal downloads, a folder of segments for HLS.
    public var partURL: URL {
        URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(fileName + FileNaming.partSuffix)
    }

    /// 0…1, or nil while the size is unknown.
    public var fractionDone: Double? {
        if status == .completed { return 1 }
        if kind == .hls, let count = hls?.segmentCount, count > 0 {
            return Double(hls?.completedSegments.count ?? 0) / Double(count)
        }
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(total))
    }

    public var isActive: Bool { status == .downloading }

    /// Clear everything learned from the server so the next run starts from byte zero.
    public mutating func resetProgress() {
        pieces = []
        receivedBytes = 0
        validator = nil
        resumable = nil
        totalBytes = kind == .hls ? totalBytes : nil
        if kind == .hls { hls?.completedSegments = [] }
        failure = nil
        attempts = 0
        checksumState = nil
        activeDuration = 0
        startedAt = nil
        finishedAt = nil
    }
}
