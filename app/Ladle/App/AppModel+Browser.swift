import AppKit
import Foundation
import LadleKit

/// Hand-offs from browsers: LadleBridge (Chrome family, Firefox), Safari's extension, `ladle://` links.
extension AppModel {
    /// Answers LadleBridge. Runs on the main thread, synchronously.
    func handleBridge(_ envelope: BridgeEnvelope) -> BridgeReply {
        let request = envelope.request
        let browser = request.browser ?? envelope.browser ?? "your browser"
        browsers.record(browser: browser)
        if let port = envelope.replyPort {
            bridgePorts[BrowserIntegration.family(forBrowser: browser).rawValue] = port
        }
        if request.type == "hello" {
            // The trust token is for Safari's extension, which reads the settings file itself; the
            // other browsers' extension has no use for it, so it never leaves the Mac's own files.
            var snapshot = browsers.snapshot(for: settings)
            snapshot.token = ""
            return BridgeReply(replyTo: request.id, ok: true, settings: snapshot)
        }
        guard let handOff = request.handOff(source: browser) else {
            return BridgeReply(replyTo: request.id, ok: false, error: "unsupported")
        }
        if handOff.mode == .caught, let url = handOff.urls.first {
            let key = url.absoluteString
            if let when = returnedToBrowser[key], Date().timeIntervalSince(when) < 120 {
                // The person gave this one back to the browser a moment ago.
                returnedToBrowser[key] = nil
                return BridgeReply(replyTo: request.id, ok: false, error: "letBrowser")
            }
        }
        receive(handOff, origin: .bridge(port: envelope.replyPort, browser: browser), userAgent: request.userAgent)
        return BridgeReply(replyTo: request.id, ok: true)
    }

    /// Decides what a hand-off does: the catch panel, straight into the list, or the add sheet.
    func receive(_ handOff: HandOff, origin: HandOffOrigin, userAgent: String?) {
        lastHandOff = Date()
        var handOff = handOff
        if !origin.isTrusted {
            // Any web page can open a ladle:// link. Its cookies and referrer would let the page choose
            // the headers Ladle sends, and its source and size would be shown as if a browser said so.
            handOff.cookies = nil
            handOff.referrer = nil
            handOff.source = nil
            handOff.size = nil
        }
        var requests = DownloadRequest.from(handOff, userAgent: userAgent)
        guard !requests.isEmpty else { return }
        if handOff.isBatch {
            // "Download All Links with Ladle…": the page's file links, checked, to choose from. For a
            // web page's list, no server is contacted until the person adds the links.
            let context = AddSheetContext(referrer: handOff.referrer, source: handOff.source, userAgent: userAgent, checksServers: origin.isTrusted)
            openAddSheet(text: handOff.urls.map(\.absoluteString).joined(separator: "\n"), context: context)
            return
        }
        // The video button on a plain video file: name it after the page.
        if handOff.mode == .direct, handOff.kind == .file, let title = handOff.title, !title.isEmpty {
            let ext = FileNaming.fileExtension(of: requests[0].url.lastPathComponent)
            requests[0].fileName = FileNaming.sanitize(title) + "." + (ext.isEmpty ? "mp4" : ext)
        }
        let request = requests[0]
        let trusted: Bool
        if case .link(let isTrusted) = origin { trusted = isTrusted } else { trusted = true }
        let ext = FileNaming.fileExtension(of: request.initialName)
        let ask = !trusted || (handOff.mode == .caught && settings.shouldAsk(forExtension: ext))
        if ask {
            catchPanel.ask(CatchRequest(request: request, origin: origin, browserName: handOff.source))
        } else {
            Task { [weak self] in
                guard let self else { return }
                let ids = await self.add([request], start: .now)
                if let id = ids.first { self.catchPanel.follow(id) }
            }
        }
    }

    // MARK: - Catch panel answers

    func catchDownload(_ caught: CatchRequest, alwaysForType: Bool, folder: String?) {
        var request = caught.request
        if let folder { request.directory = folder }
        if alwaysForType {
            let ext = FileNaming.fileExtension(of: request.initialName)
            if !ext.isEmpty && !settings.alwaysDownloadTypes.contains(ext) {
                settings.alwaysDownloadTypes.append(ext)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let ids = await self.add([request], start: .now)
            if let id = ids.first { self.catchPanel.follow(id) } else { self.catchPanel.close() }
        }
    }

    /// "Later": into the list without starting it.
    func catchLater(_ caught: CatchRequest, folder: String?) {
        var request = caught.request
        if let folder { request.directory = folder }
        Task { await add([request], start: .later) }
    }

    /// "Let the browser handle it": the browser downloads it itself, this once.
    func letBrowserHandle(_ caught: CatchRequest) {
        let url = caught.request.url
        switch caught.origin {
        case .bridge(let port, _):
            returnedToBrowser[url.absoluteString] = Date()
            let message = BridgePush(type: "browserDownload", url: url.absoluteString, filename: caught.request.fileName, referrer: caught.request.referrer?.absoluteString)
            if let port, BridgeServer.push(message, to: port) { return }
            NSWorkspace.shared.open(url)
        case .safari:
            browsers.openInSafari(url)
        case .link:
            NSWorkspace.shared.open(url)
        }
    }
}
