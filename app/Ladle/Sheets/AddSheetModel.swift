import AppKit
import Combine
import Foundation
import LadleKit

/// Where links handed to the sheet came from: "Download All Links with Ladle…" passes the page.
struct AddSheetContext: Equatable {
    var referrer: URL?
    var source: String?
    var userAgent: String?
    /// Off for a list a web page handed over: its servers are contacted only once the links are added.
    var checksServers = true
}

/// The add sheet: one link with a preview, or many links (series expanded) with checkboxes.
@MainActor
final class AddSheetModel: ObservableObject, Identifiable {
    struct Entry: Identifiable, Equatable {
        let id: String
        var link: ParsedLink
        var plan: AddPlan?
        var checked: Bool
        var name: String
        var size: Int64?
        var resumable: Bool?
        var failure: DownloadFailure?

        var url: URL { link.url }
    }

    let id = UUID()
    @Published var text: String {
        didSet { scheduleParse() }
    }
    @Published var start: StartChoice = .now
    @Published private(set) var entries: [Entry] = []
    /// A folder picked with "Save to" (one link only; many links go to their category folders).
    @Published var directory: String?
    @Published private(set) var fromClipboard: Bool

    let context: AddSheetContext?
    private weak var model: AppModel?
    private var parseTask: Task<Void, Never>?
    private var inspected: [String: LinkInspection] = [:]
    private var inspecting: Set<String> = []
    private var unchecked: Set<String> = []
    private var touched: Set<String> = []

    init(model: AppModel, text: String, fromClipboard: Bool, context: AddSheetContext? = nil) {
        self.model = model
        self.text = text
        self.fromClipboard = fromClipboard
        self.context = context
        scheduleParse(immediately: true)
    }

    // MARK: Derived

    /// The list with checkboxes: several links, a series, or a page's links (even just one).
    var isMany: Bool {
        context != nil || entries.count > 1 || text.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n") || LinkParser.containsSeries(text)
    }

    var title: String {
        isMany ? "Add \(entries.count) download\(entries.count == 1 ? "" : "s")" : "Add a download"
    }

    var single: Entry? { isMany ? nil : entries.first }

    var checkedEntries: [Entry] { entries.filter(\.checked) }

    /// "That doesn’t look like a link yet": something typed, nothing usable.
    var showsBadLink: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entries.isEmpty
    }

    var canConfirm: Bool { !checkedEntries.isEmpty }

    var hint: String {
        if let source = context?.source, let host = context?.referrer?.host {
            return "From \(host) in \(source)"
        }
        return fromClipboard ? "Found on your clipboard" : "Tip: you can also drop links anywhere on the window"
    }

    var tonightLabel: String {
        "Tonight, " + TonightWindow.timeLabel(minute: model?.settings.tonightStartMinute ?? 60)
    }

    var confirmTitle: String {
        let count = checkedEntries.count
        if isMany {
            return start == .tonight ? "Add \(count) to Tonight" : "Download \(count)"
        }
        return start == .tonight ? "Add to Tonight" : "Download"
    }

    /// "3 files · 1.49 GB" (size only when every checked file's size is known).
    var summary: String {
        let checked = checkedEntries
        let files = "\(checked.count) file\(checked.count == 1 ? "" : "s")"
        let sizes = checked.compactMap(\.size)
        guard !checked.isEmpty, sizes.count == checked.count else { return files }
        return files + " · " + Format.size(sizes.reduce(0, +))
    }

    var connectionsLine: String {
        "\(model?.settings.connectionsPerDownload ?? 8) connections, chosen automatically"
    }

    func folderLine(for entry: Entry) -> String {
        if let directory { return Destination.displayPath(directory) }
        return model?.displayFolder(forFileName: entry.name) ?? ""
    }

    func subtitle(for entry: Entry) -> String {
        if entry.plan?.alreadyDownloaded == true { return "Already downloaded, skipped" }
        if entry.plan?.alreadyInList == true { return "Already in your list" }
        if entry.failure != nil && entry.size == nil { return (entry.url.host ?? "") + " · couldn’t check it" }
        return (entry.url.host ?? "") + " · " + FileCategory.forFileName(entry.name).title
    }

    // MARK: Actions

    func toggle(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].checked.toggle()
        touched.insert(entry.id)
        if entries[index].checked { unchecked.remove(entry.id) } else { unchecked.insert(entry.id) }
    }

    func pasteFromClipboard() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        fromClipboard = true
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        if let model {
            panel.directoryURL = model.settings.saveFolder()
        }
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
        }
    }

    func confirm() {
        guard let model else { return }
        let chosen = checkedEntries
        guard !chosen.isEmpty else { return }
        let folder = isMany ? nil : directory
        let context = self.context
        let requests = chosen.map { entry in
            DownloadRequest(
                url: entry.url,
                referrer: context?.referrer,
                userAgent: context?.userAgent,
                checksum: entry.link.checksum,
                source: context?.source ?? "Add sheet",
                directory: folder
            )
        }
        let start = self.start
        model.closeAddSheet()
        Task { await model.add(requests, start: start) }
    }

    // MARK: Parsing and checking links

    private func scheduleParse(immediately: Bool = false) {
        parseTask?.cancel()
        parseTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            await self?.parse()
        }
    }

    private func parse() async {
        guard let model else { return }
        let links = Array(LinkParser.parseBatch(text).prefix(500))
        let plans = await model.coordinator.plan(links.map { DownloadRequest(url: $0.url, checksum: $0.checksum) })
        guard !Task.isCancelled else { return }
        var next: [Entry] = []
        for (link, plan) in zip(links, plans) {
            let key = link.url.absoluteString
            let found = inspected[key]
            let checked = touched.contains(key) ? !unchecked.contains(key) : !plan.isSkippedByDefault
            next.append(Entry(
                id: key,
                link: link,
                plan: plan,
                checked: checked,
                name: found.flatMap { $0.failure == nil ? $0.fileName : nil } ?? plan.fileName,
                size: found?.size,
                resumable: found.map(\.resumable),
                failure: found?.failure
            ))
        }
        entries = next
        inspectMissing()
    }

    /// Asks each server for size and name, a few at a time.
    private func inspectMissing() {
        guard let model, context?.checksServers != false else { return }
        let pending = entries.map(\.url).filter { inspected[$0.absoluteString] == nil && !inspecting.contains($0.absoluteString) }
        let batch = Array(pending.prefix(max(0, 6 - inspecting.count)))
        for url in batch {
            let key = url.absoluteString
            inspecting.insert(key)
            let coordinator = model.coordinator
            let context = self.context
            Task { [weak self] in
                let found = await coordinator.inspect(url, referrer: context?.referrer, userAgent: context?.userAgent)
                guard let self else { return }
                self.inspecting.remove(key)
                self.inspected[key] = found
                if let index = self.entries.firstIndex(where: { $0.id == key }) {
                    if found.failure == nil { self.entries[index].name = found.fileName }
                    self.entries[index].size = found.size
                    self.entries[index].resumable = found.resumable
                    self.entries[index].failure = found.failure
                }
                self.inspectMissing()
            }
        }
    }
}
