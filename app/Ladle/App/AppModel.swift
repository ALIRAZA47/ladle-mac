import AppKit
import Foundation
import LadleKit
import SwiftUI

/// Whether the menu bar item is shown. Kept apart from AppModel so the app's scene
/// doesn't redraw on every progress update.
@MainActor
final class MenuBarVisibility: ObservableObject {
    static let shared = MenuBarVisibility()
    @Published var isInserted = true
}

/// A link Ladle found on the clipboard.
struct ClipboardOffer: Equatable {
    var url: URL
    var name: String

    var host: String { url.host ?? "" }
}

/// How a hand-off reached Ladle. It decides what "Let the browser handle it" does.
enum HandOffOrigin: Equatable {
    /// Chrome, Arc, Edge, Brave or Firefox through LadleBridge.
    case bridge(port: String?, browser: String)
    /// Safari's extension (it opens `ladle://` links).
    case safari
    /// A `ladle://` link from anywhere else. Untrusted ones always ask first.
    case link(trusted: Bool)
}

/// The app's state for every window: the download list from LadleKit, settings, selection and
/// what the person is doing right now. All of it lives on the main actor.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let paths: AppPaths
    let transport: URLSessionTransport
    let coordinator: DownloadCoordinator
    let browsers: BrowserIntegration
    let updates: UpdateController
    let catchPanel: CatchPanelController
    let clipboard = ClipboardWatcher()
    private let settingsStore: JSONFileStore<LadleKit.Settings>
    let isFirstLaunch: Bool

    @Published private(set) var snapshot = CoordinatorSnapshot()
    @Published var settings: LadleKit.Settings {
        didSet { settingsChanged(from: oldValue) }
    }
    @Published var selection: LibrarySelection = .all
    @Published var selectedID: UUID?
    /// The link bar: a link to download, or text to search the list.
    @Published var linkText = "" {
        didSet { linkTextChanged() }
    }
    @Published var linkInspection: LinkInspection?
    @Published var showCompleted = false
    @Published var clipboardOffer: ClipboardOffer?
    @Published var addSheet: AddSheetModel?
    /// Bumped to move keyboard focus to the link bar (⌘K).
    @Published var linkBarFocusRequest = 0
    @Published var isEditingText = false
    @Published var dropTargeted = false

    private let notifications = NotificationController()
    private let dock = DockTileController()
    private let finder = FinderProgressController()
    private let power = PowerMonitor()
    private let network = NetworkMonitor()
    private let sleepWake = SleepWakeObserver()
    private let idleSleep = IdleSleepBlocker()
    private let bridge = BridgeServer()
    /// Clipboard links answered with "Not now" (or already taken) this session.
    var dismissedClipboard: Set<String> = []
    /// Links given back to the browser, so its next catch of them is waved through.
    var returnedToBrowser: [String: Date] = [:]
    /// LadleBridge ports by browser family, for pushes.
    var bridgePorts: [String: String] = [:]
    var inspectTask: Task<Void, Never>?
    /// When the last browser hand-off arrived (a launch for one doesn't open the window).
    var lastHandOff = Date.distantPast
    private var started = false
    private var applyingLoginState = false
    var isTerminating = false

    /// Set by the app delegate.
    var showMainWindow: (() -> Void)?
    var showSettingsWindow: (() -> Void)?

    private init() {
        paths = AppPaths.standard()
        settingsStore = JSONFileStore(url: paths.settings)
        let loaded = settingsStore.load()
        isFirstLaunch = loaded == nil
        var initial = (loaded ?? LadleKit.Settings()).normalized()
        if !isFirstLaunch {
            // Login items can be changed in System Settings; that is the truth.
            initial.openAtLogin = LoginItem.isEnabled
        }
        settings = initial
        transport = URLSessionTransport(configuration: AppModel.sessionConfiguration(proxy: initial.proxy), userAgent: AppModel.userAgent)
        let environment = DownloadCoordinator.Environment(transport: transport, muxer: AVMuxer(), recycler: TrashRecycler())
        coordinator = DownloadCoordinator(paths: paths, settings: initial, environment: environment)
        browsers = BrowserIntegration(paths: paths)
        updates = UpdateController()
        catchPanel = CatchPanelController()
    }

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Ladle/\(version) (Macintosh)"
    }

    static func sessionConfiguration(proxy: ProxyMode) -> URLSessionConfiguration {
        let configuration = URLSessionTransport.defaultConfiguration()
        if proxy == .none {
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0,
                "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 0,
                "ProxyAutoDiscoveryEnable": 0,
            ]
        }
        return configuration
    }

    // MARK: - Start

    func start() {
        guard !started else { return }
        started = true
        MenuBarVisibility.shared.isInserted = settings.showInMenuBar
        applyAppearance()
        if isFirstLaunch {
            try? settingsStore.save(settings)
            if settings.openAtLogin { applyLoginItem() }
        }

        notifications.onOpen = { [weak self] id in
            MainActor.assumeIsolated { self?.openItem(id) }
        }
        notifications.onReveal = { [weak self] id in
            MainActor.assumeIsolated { self?.revealItem(id) }
        }
        notifications.start()
        if settings.notifyWhenFinished { notifications.requestAuthorization() }

        finder.onPause = { [weak self] id in
            MainActor.assumeIsolated { self?.pause(id) }
        }

        browsers.writeSnapshot(settings)
        browsers.repairNativeHosts()
        browsers.refreshSafariState()
        bridge.handler = { [weak self] envelope in
            MainActor.assumeIsolated {
                self?.handleBridge(envelope) ?? BridgeReply(replyTo: envelope.request.id, ok: false, error: "starting")
            }
        }
        bridge.start()

        catchPanel.model = self

        let coordinator = self.coordinator
        Task { await coordinator.start() }
        Task { [weak self] in
            for await snapshot in coordinator.snapshots {
                self?.apply(snapshot)
            }
        }
        Task { [weak self] in
            for await event in coordinator.events {
                self?.handle(event)
            }
        }

        power.onChange = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBatteryHold() }
        }
        power.start()
        network.onChange = { [weak self] offline, constrained in
            MainActor.assumeIsolated { self?.networkChanged(offline: offline, constrained: constrained) }
        }
        network.start()
        sleepWake.onSleep = { [weak self] in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }
        sleepWake.onWake = { [weak self] in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
        sleepWake.start()

        clipboard.onLink = { [weak self] text in
            MainActor.assumeIsolated { self?.considerClipboard(text) }
        }
        if settings.watchClipboard { clipboard.start() }

        updates.start()
    }

    // MARK: - Snapshots and events

    private func apply(_ next: CoordinatorSnapshot) {
        snapshot = next
        let downloading = next.items.filter { $0.status == .downloading }
        dock.update(progress: AppModel.overallProgress(downloading), downloading: downloading.count)
        finder.sync(next.items)
        idleSleep.set(active: !downloading.isEmpty)
        catchPanel.refresh()
    }

    static func overallProgress(_ downloading: [DownloadItem]) -> Double? {
        let sized = downloading.filter { ($0.totalBytes ?? 0) > 0 }
        guard !downloading.isEmpty else { return nil }
        let total = sized.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        guard total > 0 else { return 0 }
        let done = sized.reduce(Int64(0)) { $0 + $1.receivedBytes }
        return min(1, Double(done) / Double(total))
    }

    private func handle(_ event: CoordinatorEvent) {
        switch event {
        case .finished(let item):
            if settings.notifyWhenFinished { notifications.postFinished(item, sound: settings.playSound) }
            switch settings.finishAction {
            case .open: open(item)
            case .showInFinder: reveal(item)
            case .notify: break
            }
            catchPanel.downloadFinished(item)
        case .failed(let item):
            catchPanel.downloadFailed(item)
        case .tonightQueueFinished:
            guard settings.whenTonightFinishes == .sleep else { return }
            // A moment for files and state to settle, then sleep unless something started.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.snapshot.items.contains(where: { $0.status == .downloading }) else { return }
                    MacSleeper.sleepNow()
                }
            }
        }
    }

    // MARK: - Holds

    private func updateBatteryHold() {
        let active = settings.pauseOnBattery && power.onBattery
        let coordinator = self.coordinator
        Task { await coordinator.setHold(.battery, active: active) }
    }

    private var lastConstrained = false

    private func networkChanged(offline: Bool, constrained: Bool) {
        lastConstrained = constrained
        let lowData = settings.pauseOnLowData && constrained
        let coordinator = self.coordinator
        Task {
            await coordinator.setHold(.offline, active: offline)
            await coordinator.setHold(.lowData, active: lowData)
        }
    }

    private func systemWillSleep() {
        let coordinator = self.coordinator
        Task { await coordinator.setHold(.sleeping, active: true) }
    }

    private func systemDidWake() {
        let coordinator = self.coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Task { await coordinator.setHold(.sleeping, active: false) }
        }
    }

    // MARK: - Settings

    private func settingsChanged(from old: LadleKit.Settings) {
        let normalized = settings.normalized()
        if normalized != settings { settings = normalized }
        try? settingsStore.save(settings)
        let current = settings
        let coordinator = self.coordinator
        Task { await coordinator.update(settings: current) }
        if old.appearance != current.appearance { applyAppearance() }
        if old.openAtLogin != current.openAtLogin && !applyingLoginState { applyLoginItem() }
        if old.showInMenuBar != current.showInMenuBar { MenuBarVisibility.shared.isInserted = current.showInMenuBar }
        if old.catchFileTypes != current.catchFileTypes || old.askBeforeDownloading != current.askBeforeDownloading
            || old.alwaysDownloadTypes != current.alwaysDownloadTypes || old.saveFolderPath != current.saveFolderPath
            || old.sortIntoCategoryFolders != current.sortIntoCategoryFolders {
            browsers.writeSnapshot(current)
            pushSettingsToBrowsers()
        }
        if old.pauseOnBattery != current.pauseOnBattery { updateBatteryHold() }
        if old.pauseOnLowData != current.pauseOnLowData {
            let lowData = current.pauseOnLowData && lastConstrained
            Task { await coordinator.setHold(.lowData, active: lowData) }
        }
        if old.watchClipboard != current.watchClipboard {
            if current.watchClipboard {
                clipboard.start()
            } else {
                clipboard.stop()
                clipboardOffer = nil
            }
        }
        if old.proxy != current.proxy {
            transport.replaceConfiguration(AppModel.sessionConfiguration(proxy: current.proxy))
        }
        if !old.notifyWhenFinished && current.notifyWhenFinished { notifications.requestAuthorization() }
    }

    func applyAppearance() {
        switch settings.appearance {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func applyLoginItem() {
        do {
            try LoginItem.set(settings.openAtLogin)
        } catch {
            // macOS said no (for example, waiting for approval): show what's really set.
            applyingLoginState = true
            settings.openAtLogin = LoginItem.isEnabled
            applyingLoginState = false
        }
    }

    private func pushSettingsToBrowsers() {
        let message = BridgePush(type: "settings", settings: browsers.snapshot(for: settings))
        for (family, port) in bridgePorts where !BridgeServer.push(message, to: port) {
            bridgePorts[family] = nil
        }
    }

    // MARK: - List

    var items: [DownloadItem] { snapshot.items }

    /// The link in the link bar, with its checksum when one was pasted after it.
    var linkParsed: ParsedLink? { LinkParser.singleLink(from: linkText) }
    var linkURL: URL? { linkParsed?.url }

    /// What the list is filtered by: the link bar's text, unless it's a link.
    var searchText: String { linkURL == nil ? linkText : "" }

    var visibleItems: [DownloadItem] {
        ListPresentation.filter(items, selection: selection, search: searchText)
    }

    var groups: [ItemGroup] {
        ListPresentation.groups(items, selection: selection, search: searchText, showCompleted: showCompleted, now: snapshot.date)
    }

    /// The selected download, or the first unfinished one in view, like the design.
    var selectedItem: DownloadItem? {
        let visible = visibleItems
        if let id = selectedID, let item = visible.first(where: { $0.id == id }) { return item }
        return visible.first(where: { $0.status != .completed }) ?? visible.first
    }

    func live(_ item: DownloadItem) -> LiveInfo? {
        snapshot.live[item.id]
    }

    func waitReason(_ item: DownloadItem) -> WaitReason? {
        LadleKit.Scheduler.waitReason(for: item, settings: settings, holds: snapshot.holds, now: snapshot.date)
    }

    func item(_ id: UUID) -> DownloadItem? {
        items.first(where: { $0.id == id })
    }

    var totalSpeed: Double { snapshot.totalSpeed }

    var downloadingCount: Int { items.filter { $0.status == .downloading }.count }

    func count(_ selection: LibrarySelection) -> Int {
        selection.count(in: items)
    }

    /// Moves the selection up or down the visible list (arrow keys).
    func moveSelection(by step: Int) {
        let ordered = groups.flatMap(\.items)
        guard !ordered.isEmpty else { return }
        guard let current = selectedItem, let index = ordered.firstIndex(where: { $0.id == current.id }) else {
            selectedID = ordered.first?.id
            return
        }
        let next = min(max(0, index + step), ordered.count - 1)
        selectedID = ordered[next].id
    }

    // MARK: - Actions on downloads

    func pause(_ id: UUID) {
        let coordinator = self.coordinator
        Task { await coordinator.pause(id) }
    }

    func resume(_ id: UUID) {
        let coordinator = self.coordinator
        Task { await coordinator.resume(id) }
    }

    func startNow(_ id: UUID) {
        let coordinator = self.coordinator
        Task { await coordinator.startNow(id) }
    }

    func retry(_ id: UUID) {
        let coordinator = self.coordinator
        Task { await coordinator.retry(id) }
    }

    func startOver(_ id: UUID) {
        let coordinator = self.coordinator
        Task { await coordinator.startOver(id) }
    }

    func remove(_ id: UUID) {
        if selectedID == id { selectedID = nil }
        let coordinator = self.coordinator
        Task { await coordinator.remove(id) }
    }

    func open(_ item: DownloadItem) {
        guard item.status == .completed, FileManager.default.fileExists(atPath: item.finalURL.path) else {
            reveal(item)
            return
        }
        NSWorkspace.shared.open(item.finalURL)
    }

    func reveal(_ item: DownloadItem) {
        let candidates = [item.finalURL, item.partURL]
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.activateFileViewerSelecting([existing])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.directory, isDirectory: true))
        }
    }

    func openItem(_ id: UUID) {
        if let item = item(id) { open(item) }
    }

    func revealItem(_ id: UUID) {
        if let item = item(id) { reveal(item) }
    }

    func copyLink(_ item: DownloadItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
    }

    func perform(_ action: PrimaryAction, on item: DownloadItem) {
        switch action {
        case .pause: pause(item.id)
        case .start, .resume: resume(item.id)
        case .startNow: startNow(item.id)
        case .retry: retry(item.id)
        case .startOver: startOver(item.id)
        case .open: open(item)
        }
    }

    /// Space: pause or resume the selected download.
    func toggleSelected() {
        guard let item = selectedItem else { return }
        switch item.status {
        case .downloading, .queued: pause(item.id)
        case .paused: resume(item.id)
        case .failed: retry(item.id)
        case .completed: break
        }
    }

    var pauseAllPauses: Bool {
        ListPresentation.pauseAllPauses(items)
    }

    /// ⌥⌘P and the header button.
    func togglePauseAll() {
        let coordinator = self.coordinator
        if pauseAllPauses {
            Task { await coordinator.pauseAll() }
        } else {
            Task { await coordinator.resumeAll() }
        }
    }

    func toggleSpeedLimit() {
        settings.limitSpeed.toggle()
    }

    // MARK: - Quitting

    func prepareForQuit() async {
        finder.stopAll()
        bridge.stop()
        await coordinator.prepareForQuit()
    }
}
