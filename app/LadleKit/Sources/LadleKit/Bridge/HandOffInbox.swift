import Foundation

/// Hand-offs the Safari extension leaves for Ladle as files, one request per file, so a page's
/// cookies never travel inside a URL and no other app that claims the `ladle:` scheme can receive
/// them. Ladle creates the folder (`AppPaths.inbox`) and reads each file once; the extension's
/// sandbox may write there and nowhere else in Ladle's data.
public enum HandOffInbox {
    /// A hand-off older than this was never collected and is thrown away.
    public static let maxAge: TimeInterval = 300

    /// Writes `request` as `<id>.json` and returns the id for the `ladle://inbox?id=…` link.
    @discardableResult
    public static func drop(_ request: BridgeRequest, in directory: URL) throws -> String {
        let id = UUID().uuidString
        try NativeMessaging.encode(request).write(to: file(id, in: directory), options: [.atomic])
        return id
    }

    /// The link that tells Ladle to collect a dropped hand-off.
    public static func link(id: String) -> URL? {
        URL(string: "ladle://inbox?id=\(id)")
    }

    /// Reads and removes the hand-off with this id; nil when there is none, or it's too old to be the
    /// one just opened. The id must be a UUID, so a link can't name any other file.
    public static func take(id: String, from directory: URL, now: Date = Date()) -> BridgeRequest? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let fileManager = FileManager.default
        let url = file(uuid.uuidString, in: directory)
        defer { try? fileManager.removeItem(at: url) }
        guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(modified) < maxAge,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BridgeRequest.self, from: data)
    }

    /// Removes hand-offs nobody collected.
    public static func sweep(_ directory: URL, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(modified) >= maxAge { try? fileManager.removeItem(at: url) }
        }
    }

    static func file(_ id: String, in directory: URL) -> URL {
        directory.appendingPathComponent(id + ".json")
    }
}
