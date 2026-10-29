import AppKit
import LadleKit
import SwiftUI

/// A download a browser handed over, waiting for the person's answer.
struct CatchRequest: Identifiable, Equatable {
    let id = UUID()
    var request: DownloadRequest
    var origin: HandOffOrigin
    var browserName: String?

    /// "handbrake.fr": the page's site when known, else the file's.
    var site: String {
        request.referrer?.host ?? request.url.host ?? ""
    }
}

/// The browser hand-off panel at the top right of the screen: it asks, then shrinks into a progress
/// pill while the file pours, then shows a done pill with Open and Show in Finder.
@MainActor
final class CatchPanelController: ObservableObject {
    enum Stage: Equatable {
        case ask(CatchRequest)
        case pouring(UUID)
        case done(UUID)
    }

    @Published private(set) var stage: Stage?
    @Published var alwaysForType = false
    @Published private(set) var folder: String?
    @Published private(set) var inspection: LinkInspection?

    weak var model: AppModel?
    private var waiting: [CatchRequest] = []
    private var panel: CatchPanel?
    private var hosting: NSHostingView<AnyView>?
    private var hideTimer: Timer?

    // MARK: Flow

    func ask(_ request: CatchRequest) {
        if case .ask = stage {
            waiting.append(request)
            return
        }
        alwaysForType = false
        folder = nil
        inspection = nil
        show(.ask(request))
        guard let model else { return }
        let coordinator = model.coordinator
        let url = request.request.url
        let referrer = request.request.referrer
        let cookies = request.request.cookies
        let agent = request.request.userAgent
        Task { [weak self] in
            let found = await coordinator.inspect(url, referrer: referrer, cookies: cookies, userAgent: agent)
            guard let self, case .ask(let current)? = self.stage, current.id == request.id else { return }
            self.inspection = found
            self.resize()
        }
    }

    /// Shows the progress pill for a download that just started from the browser.
    func follow(_ id: UUID) {
        if case .ask = stage { return }
        show(.pouring(id))
    }

    func downloadFinished(_ item: DownloadItem) {
        guard stage == .pouring(item.id) else { return }
        show(.done(item.id))
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func downloadFailed(_ item: DownloadItem) {
        if stage == .pouring(item.id) { close() }
    }

    /// Called on every list update.
    func refresh() {
        switch stage {
        case .pouring(let id)?, .done(let id)?:
            if model?.item(id) == nil { close() }
        default:
            break
        }
    }

    func close() {
        hideTimer?.invalidate()
        hideTimer = nil
        stage = nil
        if let next = waiting.first {
            waiting.removeFirst()
            ask(next)
            return
        }
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self, self.stage == nil else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    // MARK: Answers

    private var asking: CatchRequest? {
        if case .ask(let request)? = stage { return request }
        return nil
    }

    func answerDownload() {
        guard let request = asking, let model else { return }
        let always = alwaysForType
        let chosen = folder
        stage = nil
        model.catchDownload(request, alwaysForType: always, folder: chosen)
    }

    func answerLater() {
        guard let request = asking, let model else { return }
        model.catchLater(request, folder: folder)
        close()
    }

    func answerBrowser() {
        guard let request = asking, let model else { return }
        model.letBrowserHandle(request)
        close()
    }

    func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.prompt = "Save Here"
        if open.runModal() == .OK, let url = open.url {
            folder = url.path
        }
    }

    /// Where the file will go, as shown.
    func folderLine(for request: CatchRequest) -> String {
        if let folder { return Destination.displayPath(folder) }
        let name = inspection.flatMap { $0.failure == nil ? $0.fileName : nil } ?? request.request.initialName
        return model?.displayFolder(forFileName: name) ?? ""
    }

    // MARK: Window

    private func show(_ next: Stage) {
        stage = next
        let panel = makePanelIfNeeded()
        resize()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func makePanelIfNeeded() -> CatchPanel {
        if let panel { return panel }
        let panel = CatchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = AnyView(
            Themed { CatchPanelView() }
                .environmentObject(self)
                .environmentObject(model ?? AppModel.shared)
        )
        let hosting = NSHostingView(rootView: root)
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        return panel
    }

    /// Fits the panel to its content and pins it to the top right of the screen.
    func resize() {
        Task { @MainActor [weak self] in
            guard let self, let panel = self.panel, let hosting = self.hosting else { return }
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            let screen = NSScreen.main ?? NSScreen.screens.first
            guard let visible = screen?.visibleFrame else { return }
            let origin = NSPoint(x: visible.maxX - size.width - 8, y: visible.maxY - size.height - 8)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }
}

/// A borderless panel that can still take key presses (Return for Download) without activating Ladle.
final class CatchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
