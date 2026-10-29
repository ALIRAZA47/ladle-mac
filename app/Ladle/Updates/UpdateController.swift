import AppKit
import Combine
import Foundation
import Sparkle

/// Sparkle 2, set up for seamless updates: Sparkle downloads in the background, then instead of
/// its own alert Ladle shows "Ladle X is ready" with Restart to Update and Later. Without a restart,
/// the update installs when Ladle quits.
@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastChecked: Date?
    /// Set when an update is downloaded and waiting.
    @Published private(set) var readyVersion: String?
    @Published var bannerDismissed = false

    private let delegate = UpdaterDelegate()
    private let controller: SPUStandardUpdaterController
    private var installNow: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
    }

    private var updater: SPUUpdater { controller.updater }

    func start() {
        delegate.onReady = { [weak self] version, install in
            MainActor.assumeIsolated {
                self?.updateIsReady(version: version, install: install)
            }
        }
        delegate.onCheckFinished = { [weak self] in
            MainActor.assumeIsolated {
                self?.lastChecked = self?.updater.lastUpdateCheckDate
            }
        }
        controller.startUpdater()
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
            .store(in: &cancellables)
        lastChecked = updater.lastUpdateCheckDate
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloads: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastCheckedText: String {
        guard let lastChecked else { return "Never" }
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: lastChecked)
    }

    /// "Check for Updates…" and "Check Now".
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    private func updateIsReady(version: String, install: @escaping () -> Void) {
        installNow = install
        readyVersion = version
        bannerDismissed = false
    }

    /// "Restart to Update". With downloads running, first says they'll pause and pick up after.
    func restartToUpdate(downloading: Int) {
        guard let install = installNow else { return }
        if downloading > 0 {
            let alert = NSAlert()
            alert.messageText = "Restart to update?"
            alert.informativeText = downloading == 1
                ? "The download in progress will pause and pick up where it left off after Ladle restarts."
                : "The \(downloading) downloads in progress will pause and pick up where they left off after Ladle restarts."
            alert.addButton(withTitle: "Restart to Update")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        install()
    }
}

/// Sparkle calls this on the main thread. It holds on to the install block instead of letting
/// Sparkle show its own "update ready" alert.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onReady: ((String, @escaping () -> Void) -> Void)?
    var onCheckFinished: (() -> Void)?

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard let onReady else { return false }
        onReady(item.displayVersionString, immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        onCheckFinished?()
    }
}
