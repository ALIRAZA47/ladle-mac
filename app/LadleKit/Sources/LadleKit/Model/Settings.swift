import Foundation

public enum Appearance: String, Codable, CaseIterable, Sendable {
    case auto, light, dark

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public enum DuplicatePolicy: String, Codable, CaseIterable, Sendable {
    case keepBoth, replace, ask

    public var title: String {
        switch self {
        case .keepBoth: return "Keep both"
        case .replace: return "Replace"
        case .ask: return "Ask"
        }
    }
}

public enum FinishAction: String, Codable, CaseIterable, Sendable {
    case notify, open, showInFinder

    public var title: String {
        switch self {
        case .notify: return "Just notify me"
        case .open: return "Open the file"
        case .showInFinder: return "Show in Finder"
        }
    }
}

public enum ProxyMode: String, Codable, CaseIterable, Sendable {
    case system, none

    public var title: String {
        switch self {
        case .system: return "Same as macOS"
        case .none: return "Don’t use a proxy"
        }
    }
}

public enum QueueFinishAction: String, Codable, CaseIterable, Sendable {
    case doNothing, sleep

    public var title: String {
        switch self {
        case .doNothing: return "Do nothing"
        case .sleep: return "Put the Mac to sleep"
        }
    }
}

/// Every user setting from the SPEC "Settings" table, with its default.
/// Missing keys decode to defaults so older files keep working.
public struct Settings: Codable, Equatable, Sendable {
    // General
    public var openAtLogin: Bool = true
    public var showInMenuBar: Bool = true
    public var watchClipboard: Bool = true
    public var appearance: Appearance = .auto
    public var notifyWhenFinished: Bool = true
    public var playSound: Bool = false

    // Downloads
    /// Absolute path. Empty means the default, `~/Downloads/Ladle`.
    public var saveFolderPath: String = ""
    public var sortIntoCategoryFolders: Bool = true
    public var duplicatePolicy: DuplicatePolicy = .keepBoth
    public var finishAction: FinishAction = .notify
    public var verifyChecksums: Bool = true

    // Speed
    public var maxConcurrentDownloads: Int = 3
    public var connectionsPerDownload: Int = 8
    public var limitSpeed: Bool = false
    public var speedLimitBytesPerSecond: Int64 = 10_000_000
    public var retryLimit: Int = 3
    public var proxy: ProxyMode = .system

    // Browsers
    public var catchFileTypes: [String] = Settings.defaultCatchFileTypes
    public var askBeforeDownloading: Bool = true
    /// Types the user ticked "Always download .<ext> files without asking" for.
    public var alwaysDownloadTypes: [String] = []

    // Schedule
    /// Minutes after midnight.
    public var tonightStartMinute: Int = 60
    public var tonightStopMinute: Int = 420
    /// `Calendar` weekdays, 1 = Sunday … 7 = Saturday.
    public var tonightDays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    public var whenTonightFinishes: QueueFinishAction = .sleep
    public var pauseOnBattery: Bool = true
    public var pauseOnLowData: Bool = true

    public static let defaultCatchFileTypes = ["dmg", "pkg", "zip", "iso", "mp4", "mov", "mkv", "mp3", "flac", "pdf"]
    public static let retryChoices = [0, 1, 3, 5, 10]
    public static let concurrentRange = 1...8
    public static let connectionsRange = 1...32
    public static let recommendedConnections = 8
    public static let speedLimitChoices: [Int64] = [1_000_000, 2_000_000, 5_000_000, 10_000_000, 25_000_000, 50_000_000]

    public init() {}

    public static func defaultSaveFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent("Ladle", isDirectory: true)
    }

    public func saveFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if saveFolderPath.isEmpty { return Settings.defaultSaveFolder(home: home) }
        return URL(fileURLWithPath: saveFolderPath, isDirectory: true)
    }

    /// Settings with every value forced into its allowed range.
    public func normalized() -> Settings {
        var s = self
        s.maxConcurrentDownloads = min(max(s.maxConcurrentDownloads, Settings.concurrentRange.lowerBound), Settings.concurrentRange.upperBound)
        s.connectionsPerDownload = min(max(s.connectionsPerDownload, Settings.connectionsRange.lowerBound), Settings.connectionsRange.upperBound)
        if !Settings.retryChoices.contains(s.retryLimit) {
            s.retryLimit = Settings.retryChoices.min(by: { abs($0 - s.retryLimit) < abs($1 - s.retryLimit) }) ?? 3
        }
        s.speedLimitBytesPerSecond = max(100_000, s.speedLimitBytesPerSecond)
        s.tonightStartMinute = ((s.tonightStartMinute % 1440) + 1440) % 1440
        s.tonightStopMinute = ((s.tonightStopMinute % 1440) + 1440) % 1440
        s.tonightDays = Array(Set(s.tonightDays.filter { (1...7).contains($0) })).sorted()
        s.catchFileTypes = FileNaming.normalizedExtensions(s.catchFileTypes)
        s.alwaysDownloadTypes = FileNaming.normalizedExtensions(s.alwaysDownloadTypes)
        return s
    }

    /// Whether a browser hand-off of this extension should show the catch panel.
    public func shouldAsk(forExtension ext: String) -> Bool {
        askBeforeDownloading && !alwaysDownloadTypes.contains(ext.lowercased())
    }

    private enum CodingKeys: String, CodingKey {
        case openAtLogin, showInMenuBar, watchClipboard, appearance, notifyWhenFinished, playSound
        case saveFolderPath, sortIntoCategoryFolders, duplicatePolicy, finishAction, verifyChecksums
        case maxConcurrentDownloads, connectionsPerDownload, limitSpeed, speedLimitBytesPerSecond, retryLimit, proxy
        case catchFileTypes, askBeforeDownloading, alwaysDownloadTypes
        case tonightStartMinute, tonightStopMinute, tonightDays, whenTonightFinishes, pauseOnBattery, pauseOnLowData
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        openAtLogin = value(.openAtLogin, d.openAtLogin)
        showInMenuBar = value(.showInMenuBar, d.showInMenuBar)
        watchClipboard = value(.watchClipboard, d.watchClipboard)
        appearance = value(.appearance, d.appearance)
        notifyWhenFinished = value(.notifyWhenFinished, d.notifyWhenFinished)
        playSound = value(.playSound, d.playSound)
        saveFolderPath = value(.saveFolderPath, d.saveFolderPath)
        sortIntoCategoryFolders = value(.sortIntoCategoryFolders, d.sortIntoCategoryFolders)
        duplicatePolicy = value(.duplicatePolicy, d.duplicatePolicy)
        finishAction = value(.finishAction, d.finishAction)
        verifyChecksums = value(.verifyChecksums, d.verifyChecksums)
        maxConcurrentDownloads = value(.maxConcurrentDownloads, d.maxConcurrentDownloads)
        connectionsPerDownload = value(.connectionsPerDownload, d.connectionsPerDownload)
        limitSpeed = value(.limitSpeed, d.limitSpeed)
        speedLimitBytesPerSecond = value(.speedLimitBytesPerSecond, d.speedLimitBytesPerSecond)
        retryLimit = value(.retryLimit, d.retryLimit)
        proxy = value(.proxy, d.proxy)
        catchFileTypes = value(.catchFileTypes, d.catchFileTypes)
        askBeforeDownloading = value(.askBeforeDownloading, d.askBeforeDownloading)
        alwaysDownloadTypes = value(.alwaysDownloadTypes, d.alwaysDownloadTypes)
        tonightStartMinute = value(.tonightStartMinute, d.tonightStartMinute)
        tonightStopMinute = value(.tonightStopMinute, d.tonightStopMinute)
        tonightDays = value(.tonightDays, d.tonightDays)
        whenTonightFinishes = value(.whenTonightFinishes, d.whenTonightFinishes)
        pauseOnBattery = value(.pauseOnBattery, d.pauseOnBattery)
        pauseOnLowData = value(.pauseOnLowData, d.pauseOnLowData)
        self = normalized()
    }
}
