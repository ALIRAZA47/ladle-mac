import AppKit
import Combine
import Foundation
import LadleKit
import SafariServices

/// Everything Ladle does for browsers: the settings file the extension reads, the native
/// messaging host manifests, and the Safari extension's state.
@MainActor
final class BrowserIntegration: ObservableObject {
    /// Chrome extension IDs allowed to talk to LadleBridge. The first is the unpacked development
    /// build (fixed by the `key` in BrowserExtension/manifests/chrome.json). Add the Chrome Web
    /// Store ID here once the extension is published (see RELEASING.md).
    static let chromeExtensionIDs = ["pleopllngomokgfeebgjmnkjhebmcmkk"]
    static let firefoxExtensionIDs = ["ladle@alirazakhan.me"]
    static let safariExtensionID = "me.alirazakhan.Ladle.SafariExtension"

    enum Family: String {
        case chrome, firefox
    }

    @Published private(set) var safariEnabled: Bool?
    @Published private(set) var lastSeen: [String: Date] = [:]

    let paths: AppPaths
    /// Proves `ladle://` links came from Ladle's own extension (Safari's handler reads it from the snapshot).
    let token: String

    private let defaults = UserDefaults.standard
    private static let tokenKey = "BrowserToken"
    private static let seenKey = "BrowserLastSeen"

    init(paths: AppPaths) {
        self.paths = paths
        if let saved = defaults.string(forKey: BrowserIntegration.tokenKey), saved.count >= 32 {
            token = saved
        } else {
            let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            defaults.set(fresh, forKey: BrowserIntegration.tokenKey)
            token = fresh
        }
        if let stored = defaults.dictionary(forKey: BrowserIntegration.seenKey) as? [String: Date] {
            lastSeen = stored
        }
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// LadleBridge inside this copy of the app.
    var bridgePath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LadleBridge").path
    }

    private var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    func snapshot(for settings: LadleKit.Settings) -> BrowserSettingsSnapshot {
        BrowserSettingsSnapshot(settings: settings, appVersion: appVersion, token: token)
    }

    /// Writes `browser-settings.json` for the helper and the Safari extension.
    func writeSnapshot(_ settings: LadleKit.Settings) {
        let store = JSONFileStore<BrowserSettingsSnapshot>(url: paths.browserSettings)
        try? store.save(snapshot(for: settings))
    }

    // MARK: Native messaging hosts

    private var chromeFamilies: [BrowserFamily] {
        let present = BrowserFamily.allCases.filter { !$0.isFirefox && $0.isPresent(home: home) }
        return present.isEmpty ? [.chrome] : present
    }

    /// Installs the host manifests so the extension can reach LadleBridge ("Get extension").
    func installNativeHosts(for family: Family) {
        let families: [BrowserFamily] = family == .firefox ? [.firefox] : chromeFamilies
        _ = try? NativeHostManifest.install(
            for: families,
            home: home,
            bridgePath: bridgePath,
            chromeOrigins: BrowserIntegration.chromeExtensionIDs,
            firefoxIDs: BrowserIntegration.firefoxExtensionIDs
        )
    }

    /// Brings installed manifests up to date: this copy of LadleBridge, and the extension IDs this
    /// version allows (store IDs get added after publishing).
    func repairNativeHosts() {
        for family in BrowserFamily.allCases {
            let file = family.manifestDirectory(home: home).appendingPathComponent("\(NativeHostManifest.hostName).json")
            guard FileManager.default.fileExists(atPath: file.path),
                  !NativeHostManifest.isCurrent(
                      for: family,
                      home: home,
                      bridgePath: bridgePath,
                      chromeOrigins: BrowserIntegration.chromeExtensionIDs,
                      firefoxIDs: BrowserIntegration.firefoxExtensionIDs
                  ) else { continue }
            _ = try? NativeHostManifest.install(
                for: [family],
                home: home,
                bridgePath: bridgePath,
                chromeOrigins: BrowserIntegration.chromeExtensionIDs,
                firefoxIDs: BrowserIntegration.firefoxExtensionIDs
            )
        }
    }

    // MARK: Status

    static func family(forBrowser name: String) -> Family {
        name.lowercased().contains("firefox") ? .firefox : .chrome
    }

    func record(browser name: String) {
        guard !name.isEmpty, name.lowercased() != "safari" else { return }
        lastSeen[BrowserIntegration.family(forBrowser: name).rawValue] = Date()
        defaults.set(lastSeen, forKey: BrowserIntegration.seenKey)
    }

    func status(for family: Family) -> String {
        lastSeen[family.rawValue] == nil ? "Not installed yet" : "Extension connected"
    }

    func isConnected(_ family: Family) -> Bool {
        lastSeen[family.rawValue] != nil
    }

    func refreshSafariState() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: BrowserIntegration.safariExtensionID) { state, _ in
            let enabled = state?.isEnabled
            Task { @MainActor [weak self] in self?.safariEnabled = enabled }
        }
    }

    func openSafariExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: BrowserIntegration.safariExtensionID) { _ in }
    }

    /// "Let the browser handle it" for Safari: open the link in Safari itself. Safari's extension only
    /// takes link clicks, so this download stays with Safari.
    func openInSafari(_ url: URL) {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
