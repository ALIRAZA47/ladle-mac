import AppKit
import Foundation
import LadleKit
import UniformTypeIdentifiers

/// Getting downloads in: the link bar, the add sheet, the clipboard, drops and links.
extension AppModel {
    // MARK: - Adding with the duplicate setting

    /// Adds downloads, asking first about names already in use when the setting says "Ask".
    @discardableResult
    func add(_ requests: [DownloadRequest], start: StartChoice) async -> [UUID] {
        guard !requests.isEmpty else { return [] }
        let plans = await coordinator.plan(requests)
        return await add(plans: plans, start: start)
    }

    @discardableResult
    func add(plans: [AddPlan], start: StartChoice) async -> [UUID] {
        guard !plans.isEmpty else { return [] }
        var choice: ConflictChoice?
        if settings.duplicatePolicy == .ask {
            let conflicts = plans.filter(\.conflict)
            if !conflicts.isEmpty {
                guard let answer = askAboutDuplicates(conflicts) else { return [] }
                choice = answer
            }
        }
        let ids = await coordinator.add(plans, start: start, conflict: choice)
        if let first = ids.first { selectedID = first }
        return ids
    }

    /// "If a file with the same name exists: Ask".
    func askAboutDuplicates(_ conflicts: [AddPlan]) -> ConflictChoice? {
        let alert = NSAlert()
        if conflicts.count == 1, let plan = conflicts.first {
            alert.messageText = "“\(plan.fileName)” already exists"
            alert.informativeText = "A file with this name is already in \(Destination.displayPath(plan.directory)). Keep both, or replace it? A replaced file goes to the Trash."
        } else {
            alert.messageText = "\(conflicts.count) files already exist"
            alert.informativeText = "Files with these names are already in their folders. Keep both, or replace them? Replaced files go to the Trash."
        }
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .replace
        default: return nil
        }
    }

    // MARK: - Link bar

    func linkTextChanged() {
        inspectTask?.cancel()
        guard let url = linkURL else {
            if linkInspection != nil { linkInspection = nil }
            return
        }
        if linkInspection?.url == url { return }
        linkInspection = nil
        let coordinator = self.coordinator
        inspectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let found = await coordinator.inspect(url)
            guard let self, !Task.isCancelled, self.linkURL == url else { return }
            self.linkInspection = found
        }
    }

    /// "Download now" in the link bar (or Return). A numbered series opens the Add sheet instead.
    func downloadLinkNow() {
        guard let parsed = linkParsed else { return }
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        linkText = ""
        if LinkParser.parseBatch(text).count > 1 {
            openAddSheet(text: text)
            return
        }
        Task { await add([DownloadRequest(url: parsed.url, checksum: parsed.checksum, source: "Link bar")], start: .now) }
    }

    /// "More options": the Add sheet with the link (and its checksum) filled in.
    func linkMoreOptions() {
        guard linkParsed != nil else { return }
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        linkText = ""
        openAddSheet(text: text)
    }

    func focusLinkBar() {
        showMainWindow?()
        linkBarFocusRequest += 1
    }

    /// Where a file with this name would be saved, as shown to people.
    func displayFolder(forFileName name: String) -> String {
        Destination.displayPath(Destination.folder(for: FileCategory.forFileName(name), settings: settings).path)
    }

    // MARK: - Add sheet

    func openAddSheet(text: String? = nil, fromClipboard: Bool = false, context: AddSheetContext? = nil) {
        showMainWindow?()
        var initial = text
        var clipboardUsed = fromClipboard
        if initial == nil, let candidate = clipboardText(), LinkParser.link(from: candidate) != nil || !LinkParser.parseBatch(candidate).isEmpty {
            initial = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            clipboardUsed = true
        }
        addSheet = AddSheetModel(model: self, text: initial ?? "", fromClipboard: clipboardUsed, context: context)
    }

    func closeAddSheet() {
        addSheet = nil
    }

    func clipboardText() -> String? {
        guard settings.watchClipboard else { return nil }
        guard let text = NSPasteboard.general.string(forType: .string), text.utf8.count < 200_000 else { return nil }
        return text
    }

    // MARK: - Clipboard

    /// Offers a file link found on the clipboard. Nothing is fetched until the person says Download:
    /// the clipboard stays on the Mac (SPEC "Privacy").
    func considerClipboard(_ text: String) {
        guard settings.watchClipboard else { return }
        let existing = Set(items.map { $0.url.absoluteString })
        guard let url = ClipboardDetector().candidate(in: text, existing: existing, dismissed: dismissedClipboard) else { return }
        guard clipboardOffer?.url != url else { return }
        clipboardOffer = ClipboardOffer(url: url, name: FileNaming.suggestedName(url: url))
    }

    func acceptClipboardOffer() {
        guard let offer = clipboardOffer else { return }
        dismissedClipboard.insert(offer.url.absoluteString)
        clipboardOffer = nil
        Task { await add([DownloadRequest(url: offer.url, source: "Clipboard")], start: .now) }
    }

    func dismissClipboardOffer() {
        guard let offer = clipboardOffer else { return }
        dismissedClipboard.insert(offer.url.absoluteString)
        clipboardOffer = nil
    }

    // MARK: - Drops and links

    /// Links dropped on the window or the Dock icon: one starts right away, several open the sheet.
    func addDroppedLinks(_ links: [URL]) {
        var seen = Set<String>()
        let unique = links.filter { seen.insert($0.absoluteString).inserted }
        guard !unique.isEmpty else { return }
        if unique.count == 1 {
            Task { await add([DownloadRequest(url: unique[0], source: "Drop")], start: .now) }
        } else {
            openAddSheet(text: unique.map(\.absoluteString).joined(separator: "\n"))
        }
    }

    /// Reads links out of drag items: URLs, `.webloc` files and text.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { AppModel.shared.receiveDropped(url) }
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                accepted = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            AppModel.shared.addDroppedLinks(LinkParser.parseBatch(text).map(\.url))
                        }
                    }
                }
            }
        }
        return accepted
    }

    func receiveDropped(_ url: URL) {
        if url.isFileURL {
            if url.pathExtension.lowercased() == "webloc", let link = Webloc.url(fromFileAt: url) {
                addDroppedLinks([link])
            }
        } else if let link = LinkParser.link(from: url.absoluteString) {
            addDroppedLinks([link])
        }
    }

    /// `application(_:open:)`: ladle:// links, .webloc files and web links (Dock drops).
    func open(urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == LadleURL.scheme {
                guard let handOff = LadleURL.parse(url) else { continue }
                let trusted = handOff.token != nil && handOff.token == browsers.token
                let origin: HandOffOrigin = trusted && handOff.source?.lowercased() == "safari" ? .safari : .link(trusted: trusted)
                receive(handOff, origin: origin, userAgent: nil)
            } else {
                receiveDropped(url)
            }
        }
    }
}
