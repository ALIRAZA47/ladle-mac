import Foundation

/// Browsers whose extension talks to Ladle through native messaging (Safari has its own path).
public enum BrowserFamily: String, CaseIterable, Sendable {
    case chrome, chromeBeta, chromeCanary, chromium, arc, edge, edgeBeta, edgeDev, brave, firefox

    public var displayName: String {
        switch self {
        case .chrome: return "Chrome"
        case .chromeBeta: return "Chrome Beta"
        case .chromeCanary: return "Chrome Canary"
        case .chromium: return "Chromium"
        case .arc: return "Arc"
        case .edge: return "Edge"
        case .edgeBeta: return "Edge Beta"
        case .edgeDev: return "Edge Dev"
        case .brave: return "Brave"
        case .firefox: return "Firefox"
        }
    }

    public var isFirefox: Bool { self == .firefox }

    /// Folder (under `~/Library/Application Support`) the browser reads host manifests from.
    public var supportFolder: String {
        switch self {
        case .chrome: return "Google/Chrome"
        case .chromeBeta: return "Google/Chrome Beta"
        case .chromeCanary: return "Google/Chrome Canary"
        case .chromium: return "Chromium"
        case .arc: return "Arc/User Data"
        case .edge: return "Microsoft Edge"
        case .edgeBeta: return "Microsoft Edge Beta"
        case .edgeDev: return "Microsoft Edge Dev"
        case .brave: return "BraveSoftware/Brave-Browser"
        case .firefox: return "Mozilla"
        }
    }

    public func manifestDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(supportFolder, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
    }

    /// The browser's own data folder exists, so it is (or was) installed for this user.
    public func isPresent(home: URL, fileManager: FileManager = .default) -> Bool {
        let base = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(supportFolder, isDirectory: true)
        return fileManager.fileExists(atPath: base.path)
    }
}

/// Native messaging host manifests (`me.alirazakhan.ladle.json`) for Chrome-family browsers and Firefox.
public enum NativeHostManifest {
    public static let hostName = "me.alirazakhan.ladle"

    public static func json(for family: BrowserFamily, bridgePath: String, chromeOrigins: [String], firefoxIDs: [String]) throws -> Data {
        var manifest: [String: Any] = [
            "name": hostName,
            "description": "Ladle download manager",
            "path": bridgePath,
            "type": "stdio",
        ]
        if family.isFirefox {
            manifest["allowed_extensions"] = firefoxIDs
        } else {
            manifest["allowed_origins"] = chromeOrigins.map { $0.hasPrefix("chrome-extension://") ? $0 : "chrome-extension://\($0)/" }
        }
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    }

    /// Writes the manifest for each browser. Returns the files written.
    @discardableResult
    public static func install(
        for families: [BrowserFamily],
        home: URL,
        bridgePath: String,
        chromeOrigins: [String],
        firefoxIDs: [String],
        fileManager: FileManager = .default
    ) throws -> [URL] {
        var written: [URL] = []
        for family in families {
            let folder = family.manifestDirectory(home: home)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(hostName).json")
            try json(for: family, bridgePath: bridgePath, chromeOrigins: chromeOrigins, firefoxIDs: firefoxIDs).write(to: file, options: .atomic)
            written.append(file)
        }
        return written
    }

    /// Whether a manifest is installed and points at `bridgePath`.
    public static func isInstalled(for family: BrowserFamily, home: URL, bridgePath: String) -> Bool {
        installed(for: family, home: home)?["path"] as? String == bridgePath
    }

    /// Whether the installed manifest is exactly what `install` would write now: the same helper
    /// and the same extension IDs (a store ID added in a later version counts as a change).
    public static func isCurrent(for family: BrowserFamily, home: URL, bridgePath: String, chromeOrigins: [String], firefoxIDs: [String]) -> Bool {
        guard let found = installed(for: family, home: home),
              let data = try? json(for: family, bridgePath: bridgePath, chromeOrigins: chromeOrigins, firefoxIDs: firefoxIDs),
              let wanted = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return NSDictionary(dictionary: found).isEqual(to: wanted)
    }

    private static func installed(for family: BrowserFamily, home: URL) -> [String: Any]? {
        let file = family.manifestDirectory(home: home).appendingPathComponent("\(hostName).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
