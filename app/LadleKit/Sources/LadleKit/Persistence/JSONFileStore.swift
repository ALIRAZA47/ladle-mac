import Foundation

/// Where Ladle keeps its files: `~/Library/Application Support/Ladle` on the Mac.
public struct AppPaths: Sendable {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func standard(fileManager: FileManager = .default) -> AppPaths {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppPaths(directory: base.appendingPathComponent("Ladle", isDirectory: true))
    }

    public var downloads: URL { directory.appendingPathComponent("downloads.json") }
    public var settings: URL { directory.appendingPathComponent("settings.json") }
    /// Read by the native messaging helper and the Safari extension.
    public var browserSettings: URL { directory.appendingPathComponent("browser-settings.json") }
    /// Hand-offs the Safari extension writes for Ladle (see `HandOffInbox`). Ladle creates it.
    public var inbox: URL { directory.appendingPathComponent("Inbox", isDirectory: true) }
}

/// A Codable value in a JSON file, written atomically (temporary file, then rename).
public final class JSONFileStore<Value: Codable>: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// The stored value; nil when there is no file yet. An unreadable file is set aside, not deleted.
    public func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONFileStore.decoder.decode(Value.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    public func save(_ value: Value) throws {
        let data = try JSONFileStore.encoder.encode(value)
        lock.lock()
        defer { lock.unlock() }
        let folder = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        // The files hold the download history and, while a download runs, its cookies: this user only,
        // like a browser's own profile folder.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The downloads list as stored on disk.
public struct DownloadsFile: Codable, Sendable {
    public var version: Int
    public var items: [DownloadItem]

    public init(items: [DownloadItem]) {
        self.version = 1
        self.items = items
    }
}
