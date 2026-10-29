import Foundation

/// Something to download, before it becomes a `DownloadItem`.
public struct DownloadRequest: Equatable, Sendable {
    public var url: URL
    public var kind: DownloadKind
    /// A name given by the person or the browser. Otherwise one is made from the link.
    public var fileName: String?
    /// For the video button: the page's video title becomes the name.
    public var title: String?
    public var referrer: URL?
    public var cookies: String?
    public var userAgent: String?
    public var size: Int64?
    public var mimeType: String?
    public var checksum: ExpectedChecksum?
    public var source: String?
    public var audioURL: URL?
    public var quality: String?
    public var bandwidth: Int?
    /// A folder picked by hand, instead of the category folder.
    public var directory: String?

    public init(
        url: URL,
        kind: DownloadKind = .file,
        fileName: String? = nil,
        title: String? = nil,
        referrer: URL? = nil,
        cookies: String? = nil,
        userAgent: String? = nil,
        size: Int64? = nil,
        mimeType: String? = nil,
        checksum: ExpectedChecksum? = nil,
        source: String? = nil,
        audioURL: URL? = nil,
        quality: String? = nil,
        bandwidth: Int? = nil,
        directory: String? = nil
    ) {
        self.url = url
        self.kind = kind
        self.fileName = fileName
        self.title = title
        self.referrer = referrer
        self.cookies = cookies
        self.userAgent = userAgent
        self.size = size
        self.mimeType = mimeType
        self.checksum = checksum
        self.source = source
        self.audioURL = audioURL
        self.quality = quality
        self.bandwidth = bandwidth
        self.directory = directory
    }

    /// One request per link in a hand-off.
    public static func from(_ handOff: HandOff, userAgent: String? = nil) -> [DownloadRequest] {
        handOff.urls.map { url in
            DownloadRequest(
                url: url,
                kind: handOff.kind,
                fileName: handOff.urls.count == 1 ? handOff.fileName : nil,
                title: handOff.title,
                referrer: handOff.referrer,
                cookies: handOff.cookies,
                userAgent: userAgent,
                size: handOff.urls.count == 1 ? handOff.size : nil,
                mimeType: handOff.mimeType,
                checksum: handOff.urls.count == 1 ? handOff.checksum : nil,
                source: handOff.source,
                audioURL: handOff.audioURL,
                quality: handOff.quality,
                bandwidth: handOff.bandwidth
            )
        }
    }

    /// The name the file gets before the server says otherwise.
    public var initialName: String {
        if let fileName, !fileName.isEmpty { return FileNaming.sanitize(fileName) }
        if kind == .hls {
            let base = FileNaming.sanitize(title ?? "", fallback: FileNaming.nameFromURL(url).map { FileNaming.splitExtension($0).stem } ?? "video")
            let ext = quality == "Audio only" ? "m4a" : "mp4"
            return base + "." + ext
        }
        return FileNaming.suggestedName(url: url, mimeType: mimeType)
    }
}

/// What adding a request would do, shown before it's confirmed (add sheet, catch panel, link bar).
public struct AddPlan: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var request: DownloadRequest
    public var fileName: String
    public var directory: String
    public var category: FileCategory
    /// A finished file with this name is already in the folder.
    public var conflict: Bool
    /// This link was downloaded before ("Already downloaded").
    public var alreadyDownloaded: Bool
    /// This link is in the list and not finished yet.
    public var alreadyInList: Bool

    public init(id: UUID = UUID(), request: DownloadRequest, fileName: String, directory: String, category: FileCategory, conflict: Bool, alreadyDownloaded: Bool, alreadyInList: Bool) {
        self.id = id
        self.request = request
        self.fileName = fileName
        self.directory = directory
        self.category = category
        self.conflict = conflict
        self.alreadyDownloaded = alreadyDownloaded
        self.alreadyInList = alreadyInList
    }

    /// Unchecked in the many-links list.
    public var isSkippedByDefault: Bool { alreadyDownloaded || alreadyInList }
}

public enum StartChoice: String, Sendable {
    case now, tonight
}

public enum ConflictChoice: String, Sendable {
    case keepBoth, replace
}

/// What a link turned out to be, for the link bar and the catch panel.
public struct LinkInspection: Equatable, Sendable {
    public var url: URL
    public var fileName: String
    public var size: Int64?
    public var resumable: Bool
    public var mimeType: String?
    public var failure: DownloadFailure?
}
