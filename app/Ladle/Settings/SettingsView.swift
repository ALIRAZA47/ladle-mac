import AppKit
import LadleKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, downloads, speed, browsers, schedule, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .downloads: return "Downloads"
        case .speed: return "Speed"
        case .browsers: return "Browsers"
        case .schedule: return "Schedule"
        case .updates: return "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .downloads: return "folder"
        case .speed: return "bolt"
        case .browsers: return "globe"
        case .schedule: return "moon"
        case .updates: return "arrow.down.circle"
        }
    }

    var helpPage: URL {
        switch self {
        case .general: return LadleLinks.settingsReference
        case .downloads: return LadleLinks.categoriesAndFolders
        case .speed: return LadleLinks.connectionsAndSpeed
        case .browsers: return LadleLinks.setUpBrowser
        case .schedule: return LadleLinks.tonightQueue
        case .updates: return LadleLinks.updates
        }
    }
}

/// The settings window from the Settings board, with the sixth Updates tab.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @State private var tab: SettingsTab = .general

    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(spacing: 10) {
                Text(tab.title)
                    .font(Typeface.ui(13, .semibold))
                    .foregroundStyle(palette.text)
                    .frame(height: 20)
                tabBar
                ScrollView {
                    VStack(spacing: 16) {
                        switch tab {
                        case .general: GeneralSettings()
                        case .downloads: DownloadSettings()
                        case .speed: SpeedSettings()
                        case .browsers: BrowserSettings(browsers: model.browsers)
                        case .schedule: ScheduleSettings()
                        case .updates: UpdateSettings(updates: model.updates)
                        }
                        Button("Learn more about these settings") { NSWorkspace.shared.open(tab.helpPage) }
                            .buttonStyle(InkButtonStyle(fontSize: 12))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(EdgeInsets(top: 10, leading: 56, bottom: 28, trailing: 56))
                }
            }
            .padding(.top, 14)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: 812, height: 592)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { item in
                let on = item == tab
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(on ? palette.inkOnTint : palette.text2)
                        Text(item.title)
                            .font(Typeface.ui(12.5, .medium))
                            .foregroundStyle(on ? palette.text : palette.text2)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(
                        Capsule(style: .continuous)
                            .fill(on ? Palette.accent.opacity(0.16) : Color.clear)
                    )
                    .overlay(Capsule(style: .continuous).strokeBorder(on ? Palette.accent.opacity(0.32) : Color.clear, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(palette.tile))
        .overlay(Capsule(style: .continuous).strokeBorder(palette.line, lineWidth: 1))
        .overlay(TopHighlight(radius: 22, color: palette.highlight).clipShape(Capsule()))
    }
}

// MARK: - Building blocks

/// A rounded group of rows. Put a `GroupDivider()` between rows.
struct SettingsGroup<Content: View>: View {
    @Environment(\.palette) private var palette
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(palette.tile))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
    }
}

/// The hairline between rows of a group.
struct GroupDivider: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Rectangle().fill(palette.line).frame(height: 1)
    }
}

/// A row: title (and an optional note) on the left, a control on the right.
struct SettingsRow<Control: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var note: String?
    let control: Control

    init(_ title: String, note: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.note = note
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typeface.ui(13))
                    .foregroundStyle(palette.text)
                if let note {
                    Text(note)
                        .font(Typeface.ui(11.5))
                        .foregroundStyle(palette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
    }
}

/// The pill switch with no label (the row carries it).
struct SettingsSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Toggle(isOn: $isOn) { EmptyView() }
            .toggleStyle(MoltenSwitchStyle())
            .accessibilityLabel(label)
    }
}

/// A pill-shaped pop-up menu.
struct PillMenu<Value: Hashable>: View {
    @Environment(\.palette) private var palette
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        let current = options.first(where: { $0.0 == selection })?.1 ?? ""
        Menu {
            ForEach(options.indices, id: \.self) { index in
                Button(options[index].1) { selection = options[index].0 }
            }
        } label: {
            HStack(spacing: 8) {
                Text(current)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .font(Typeface.ui(12.5))
        .foregroundStyle(palette.text)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Capsule().fill(palette.button))
        .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsGroup {
            SettingsRow("Open Ladle at login") {
                SettingsSwitch(isOn: $model.settings.openAtLogin, label: "Open Ladle at login")
            }
            GroupDivider()
            SettingsRow("Show Ladle in the menu bar") {
                SettingsSwitch(isOn: $model.settings.showInMenuBar, label: "Show Ladle in the menu bar")
            }
            GroupDivider()
            SettingsRow("Watch the clipboard for links", note: "Only links that point to a file. Nothing leaves your Mac.") {
                SettingsSwitch(isOn: $model.settings.watchClipboard, label: "Watch the clipboard for links")
            }
        }
        SettingsGroup {
            SettingsRow("Appearance") {
                PillSegmented(selection: $model.settings.appearance, options: Appearance.allCases.map { ($0, $0.title) }, height: 28)
                    .frame(width: 240)
            }
            GroupDivider()
            SettingsRow("Notify me when downloads finish") {
                SettingsSwitch(isOn: $model.settings.notifyWhenFinished, label: "Notify me when downloads finish")
            }
            GroupDivider()
            SettingsRow("Play a sound too") {
                SettingsSwitch(isOn: $model.settings.playSound, label: "Play a sound when downloads finish")
                    .disabled(!model.settings.notifyWhenFinished)
            }
        }
    }
}

// MARK: - Downloads

private struct DownloadSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        SettingsGroup {
            SettingsRow("Save downloads to") {
                Menu {
                    Button("Choose a Folder…") { chooseFolder() }
                    Button("Show in Finder") { NSWorkspace.shared.open(model.settings.saveFolder()) }
                    if !model.settings.saveFolderPath.isEmpty {
                        Divider()
                        Button("Use Downloads › Ladle") { model.settings.saveFolderPath = "" }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                        Text(Destination.displayPath(model.settings.saveFolder().path))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .font(Typeface.ui(12.5))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(palette.button))
                .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
            }
            GroupDivider()
            SettingsRow("Sort into category folders", note: "Video, Music, Documents, Archives, Apps, Images") {
                SettingsSwitch(isOn: $model.settings.sortIntoCategoryFolders, label: "Sort into category folders")
            }
        }
        SettingsGroup {
            SettingsRow("If a file with the same name exists") {
                PillMenu(selection: $model.settings.duplicatePolicy, options: DuplicatePolicy.allCases.map { ($0, $0.title) })
            }
            GroupDivider()
            SettingsRow("When a download finishes") {
                PillMenu(selection: $model.settings.finishAction, options: FinishAction.allCases.map { ($0, $0.title) })
            }
            GroupDivider()
            SettingsRow("Verify checksums", note: "When the site publishes a SHA-256 or MD5 next to the file") {
                SettingsSwitch(isOn: $model.settings.verifyChecksums, label: "Verify checksums")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = model.settings.saveFolder()
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.saveFolderPath = url.path
        }
    }
}

// MARK: - Speed

private struct SpeedSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        SettingsGroup {
            SettingsRow("Downloads at the same time") {
                HStack(spacing: 2) {
                    stepButton("minus", "Fewer") { model.settings.maxConcurrentDownloads -= 1 }
                        .disabled(model.settings.maxConcurrentDownloads <= LadleKit.Settings.concurrentRange.lowerBound)
                    Text(String(model.settings.maxConcurrentDownloads))
                        .font(Typeface.ui(13, .semibold).monospacedDigit())
                        .foregroundStyle(palette.text)
                        .frame(minWidth: 28)
                    stepButton("plus", "More") { model.settings.maxConcurrentDownloads += 1 }
                        .disabled(model.settings.maxConcurrentDownloads >= LadleKit.Settings.concurrentRange.upperBound)
                }
                .padding(3)
                .background(Capsule().fill(palette.tile))
                .overlay(Capsule().strokeBorder(palette.line, lineWidth: 1))
            }
            GroupDivider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Connections per download")
                        .font(Typeface.ui(13))
                        .foregroundStyle(palette.text)
                    Spacer()
                    let value = model.settings.connectionsPerDownload
                    Text(value == LadleKit.Settings.recommendedConnections ? "\(value) (recommended)" : String(value))
                        .font(Typeface.ui(13, .semibold).monospacedDigit())
                        .foregroundStyle(palette.ink)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.settings.connectionsPerDownload) },
                        set: { model.settings.connectionsPerDownload = Int($0.rounded()) }
                    ),
                    in: 1...32,
                    step: 1
                )
                .tint(Palette.accent)
                .accessibilityLabel("Connections per download")
                HStack {
                    Text("1")
                    Spacer()
                    Text("8")
                    Spacer()
                    Text("16")
                    Spacer()
                    Text("32")
                }
                .font(Typeface.ui(11).monospacedDigit())
                .foregroundStyle(palette.text3)
                Text("More connections are faster on servers that allow them. Ladle backs off on its own when a server pushes back.")
                    .font(Typeface.ui(11.5))
                    .foregroundStyle(palette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
        }
        SettingsGroup {
            SettingsRow("Limit total speed") {
                HStack(spacing: 12) {
                    PillMenu(selection: $model.settings.speedLimitBytesPerSecond, options: LadleKit.Settings.speedLimitChoices.map { ($0, Format.speedLimit($0)) })
                        .opacity(model.settings.limitSpeed ? 1 : 0.6)
                    SettingsSwitch(isOn: $model.settings.limitSpeed, label: "Limit total speed")
                }
            }
            GroupDivider()
            SettingsRow("Retry failed downloads") {
                PillMenu(selection: $model.settings.retryLimit, options: LadleKit.Settings.retryChoices.map { ($0, $0 == 0 ? "Never" : ($0 == 1 ? "1 time" : "\($0) times")) })
            }
            GroupDivider()
            SettingsRow("Proxy") {
                PillMenu(selection: $model.settings.proxy, options: ProxyMode.allCases.map { ($0, $0.title) })
            }
        }
    }

    private func stepButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.text2)
        .accessibilityLabel(label)
    }
}

// MARK: - Browsers

private struct BrowserSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var browsers: BrowserIntegration
    @Environment(\.palette) private var palette
    @State private var editingTypes = false

    var body: some View {
        SettingsGroup {
            let safari = browsers.safariStatus
            if safari == .needsSignedBuild {
                safariNeedsSignedBuildRow(safari)
            } else {
                browserRow("Safari", status: safari.text, good: safari == .on, action: "Manage") {
                    browsers.openSafariExtensionSettings()
                }
            }
            GroupDivider()
            browserRow(
                "Chrome, Arc, Edge and Brave",
                status: browsers.status(for: .chrome),
                good: browsers.isConnected(.chrome),
                action: "Get extension"
            ) {
                browsers.installNativeHosts(for: .chrome)
                NSWorkspace.shared.open(LadleLinks.setUpChrome)
            }
            GroupDivider()
            browserRow(
                "Firefox",
                status: browsers.status(for: .firefox),
                good: browsers.isConnected(.firefox),
                action: "Get extension"
            ) {
                browsers.installNativeHosts(for: .firefox)
                NSWorkspace.shared.open(LadleLinks.setUpFirefox)
            }
            GroupDivider()
            browserRow("Everything else", status: "Copy a link and Ladle offers to grab it", good: false, action: "How it works") {
                NSWorkspace.shared.open(LadleLinks.pasteDropOrShortcut)
            }
        }
        .onAppear { browsers.refreshSafariState() }
        SettingsGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("Catch these file types")
                    .font(Typeface.ui(13))
                    .foregroundStyle(palette.text)
                FlowLayout(spacing: 6) {
                    ForEach(model.settings.catchFileTypes, id: \.self) { ext in
                        TypeChip(text: "." + ext)
                    }
                    Button("Edit…") { editingTypes = true }
                        .buttonStyle(ChipButtonStyle())
                }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            GroupDivider()
            SettingsRow("Ask before downloading", note: "Shows the catch panel. Hold ⌥ Option while clicking to skip Ladle.") {
                SettingsSwitch(isOn: $model.settings.askBeforeDownloading, label: "Ask before downloading")
            }
        }
        .sheet(isPresented: $editingTypes) {
            Themed { FileTypesEditor() }
                .environmentObject(model)
        }
    }

    /// Free builds are ad-hoc signed, and Safari only loads extensions from signed apps: say so,
    /// link to the docs, and offer no Manage button.
    private func safariNeedsSignedBuildRow(_ status: SafariExtensionStatus) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Safari")
                    .font(Typeface.ui(13))
                    .foregroundStyle(palette.text)
                Text(status.text)
                    .font(Typeface.ui(11.5))
                    .foregroundStyle(palette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Learn more") { NSWorkspace.shared.open(LadleLinks.setUpSafari) }
                .buttonStyle(InkButtonStyle())
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    private func browserRow(_ name: String, status: String, good: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Typeface.ui(13))
                    .foregroundStyle(palette.text)
                Text(status)
                    .font(Typeface.ui(11.5))
                    .foregroundStyle(good ? palette.ink : palette.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action, action: perform)
                .buttonStyle(PillButtonStyle(kind: .glass, height: 32, fontSize: 12.5))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }
}

private struct TypeChip: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        Text(text)
            .font(Typeface.ui(12))
            .foregroundStyle(palette.text2)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(palette.button))
            .overlay(Capsule().strokeBorder(palette.line, lineWidth: 1))
    }
}

private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipButtonBody(configuration: configuration)
    }
}

private struct ChipButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.palette) private var palette

    var body: some View {
        configuration.label
            .font(Typeface.ui(12, .semibold))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(palette.button))
            .overlay(Capsule().strokeBorder(palette.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// "Catch these file types: Edit…", including the types set to download without asking.
private struct FileTypesEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var newType = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("File types Ladle catches")
                .font(Typeface.ui(16, .bold))
                .foregroundStyle(palette.text)
            Text("Downloads of these types go to Ladle instead of the browser.")
                .font(Typeface.ui(12))
                .foregroundStyle(palette.text2)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.settings.catchFileTypes, id: \.self) { ext in
                        HStack {
                            Text("." + ext)
                                .font(Typeface.ui(13))
                                .foregroundStyle(palette.text)
                            if model.settings.alwaysDownloadTypes.contains(ext) {
                                Text("never asks")
                                    .font(Typeface.ui(11.5))
                                    .foregroundStyle(palette.text3)
                                Button("Ask again") { model.settings.alwaysDownloadTypes.removeAll { $0 == ext } }
                                    .buttonStyle(InkButtonStyle(fontSize: 11.5))
                            }
                            Spacer()
                            Button {
                                model.settings.catchFileTypes.removeAll { $0 == ext }
                                model.settings.alwaysDownloadTypes.removeAll { $0 == ext }
                            } label: {
                                Image(systemName: "minus.circle").font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(palette.text3)
                            .accessibilityLabel("Stop catching .\(ext) files")
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                    }
                }
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.tile))
            HStack(spacing: 8) {
                TextField("Add a type, like epub", text: $newType)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addType)
                Button("Add", action: addType)
                    .buttonStyle(PillButtonStyle(kind: .glass, height: 30))
                    .disabled(FileNaming.normalizedExtensions([newType]).isEmpty)
            }
            HStack {
                Button("Restore Defaults") {
                    model.settings.catchFileTypes = LadleKit.Settings.defaultCatchFileTypes
                }
                .buttonStyle(InkButtonStyle(fontSize: 12))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .accent, height: 32, horizontalPadding: 18))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(palette.pop)
    }

    private func addType() {
        let types = FileNaming.normalizedExtensions([newType])
        guard let ext = types.first else { return }
        if !model.settings.catchFileTypes.contains(ext) { model.settings.catchFileTypes.append(ext) }
        newType = ""
    }
}

// MARK: - Schedule

private struct ScheduleSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    private static let times: [(Int, String)] = stride(from: 0, to: 1440, by: 30).map { ($0, TonightWindow.timeLabel(minute: $0)) }
    /// Monday first, as on the board; values are Calendar weekdays.
    private static let days: [(Int, String, String)] = [
        (2, "M", "Monday"), (3, "T", "Tuesday"), (4, "W", "Wednesday"), (5, "T", "Thursday"),
        (6, "F", "Friday"), (7, "S", "Saturday"), (1, "S", "Sunday"),
    ]

    var body: some View {
        SettingsGroup {
            SettingsRow("Tonight queue", note: "Big files wait here and download while you sleep") {
                HStack(spacing: 8) {
                    PillMenu(selection: $model.settings.tonightStartMinute, options: ScheduleSettings.times)
                        .accessibilityLabel("Start time")
                    Text("to")
                        .font(Typeface.ui(12.5))
                        .foregroundStyle(palette.text2)
                    PillMenu(selection: $model.settings.tonightStopMinute, options: ScheduleSettings.times)
                        .accessibilityLabel("Stop time")
                }
            }
            GroupDivider()
            SettingsRow("Run on") {
                HStack(spacing: 5) {
                    ForEach(ScheduleSettings.days.indices, id: \.self) { index in
                        let day = ScheduleSettings.days[index]
                        let on = model.settings.tonightDays.contains(day.0)
                        Button {
                            if on {
                                model.settings.tonightDays.removeAll { $0 == day.0 }
                            } else {
                                model.settings.tonightDays.append(day.0)
                            }
                        } label: {
                            Text(day.1)
                                .font(Typeface.ui(12, .semibold))
                                .foregroundStyle(on ? Palette.onAccent : palette.text2)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(on ? Palette.accent : palette.button))
                                .overlay(Circle().strokeBorder(on ? Palette.accent : palette.line2, lineWidth: 1))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.2)
                        .accessibilityValue(on ? "On" : "Off")
                    }
                }
            }
        }
        SettingsGroup {
            SettingsRow("When the queue finishes") {
                PillMenu(selection: $model.settings.whenTonightFinishes, options: QueueFinishAction.allCases.map { ($0, $0.title) })
            }
            GroupDivider()
            SettingsRow("Pause when running on battery", note: "Holds the Tonight queue until you plug in. Downloads you start yourself always run.") {
                SettingsSwitch(isOn: $model.settings.pauseOnBattery, label: "Pause when running on battery")
            }
            GroupDivider()
            SettingsRow("Pause on Low Data networks", note: "Holds the Tonight queue on networks in Low Data Mode, like a phone hotspot") {
                SettingsSwitch(isOn: $model.settings.pauseOnLowData, label: "Pause on Low Data networks")
            }
        }
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @ObservedObject var updates: UpdateController
    @Environment(\.palette) private var palette

    var body: some View {
        SettingsGroup {
            SettingsRow("Check for updates automatically", note: "Once a day. Sparkle sends only the app and macOS versions.") {
                SettingsSwitch(isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }), label: "Check for updates automatically")
            }
            GroupDivider()
            SettingsRow("Download and install updates automatically", note: "Updates install when Ladle restarts.") {
                SettingsSwitch(isOn: Binding(get: { updates.automaticallyDownloads }, set: { updates.automaticallyDownloads = $0 }), label: "Download and install updates automatically")
                    .disabled(!updates.automaticallyChecks)
            }
        }
        SettingsGroup {
            SettingsRow("Ladle \(updates.currentVersion)", note: "Build \(updates.currentBuild)") {
                Button("Check Now") { updates.checkForUpdates() }
                    .buttonStyle(PillButtonStyle(kind: .glass, height: 32, fontSize: 12.5))
                    .disabled(!updates.canCheckForUpdates)
            }
            GroupDivider()
            SettingsRow("Last checked") {
                Text(updates.lastCheckedText)
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(palette.text2)
            }
            GroupDivider()
            SettingsRow("What’s new") {
                Button("Release Notes") { NSWorkspace.shared.open(LadleLinks.releaseNotes(version: updates.currentVersion)) }
                    .buttonStyle(PillButtonStyle(kind: .glass, height: 32, fontSize: 12.5))
            }
        }
    }
}

// MARK: - Flow layout for chips

/// Lays chips out in rows, wrapping at the available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
