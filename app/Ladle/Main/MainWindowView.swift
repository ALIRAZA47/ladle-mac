import LadleKit
import SwiftUI
import UniformTypeIdentifiers

/// The Molten main window: a floating glass sidebar, the list, and the details panel over the glow.
struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            AmbientBackground()
            HStack(alignment: .top, spacing: 10) {
                SidebarView()
                    .frame(width: 232)
                    .frame(maxHeight: .infinity)
                VStack(spacing: 8) {
                    HeaderView()
                        .zIndex(2)
                    UpdateBannerView(updates: model.updates)
                    if let offer = model.clipboardOffer {
                        ClipboardBannerView(offer: offer)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    HStack(alignment: .top, spacing: 10) {
                        DownloadListView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        DetailsPanelView()
                            .frame(width: 312)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(10)
            .animation(.easeOut(duration: 0.2), value: model.clipboardOffer)

            if let sheet = model.addSheet {
                palette.scrim
                    .ignoresSafeArea()
                    .onTapGesture { model.closeAddSheet() }
                    .transition(.opacity)
                VStack {
                    AddSheetView(sheet: sheet)
                        .frame(maxWidth: 540)
                        .padding(.top, 62)
                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.addSheet?.id)
        .onDrop(of: [UTType.url, UTType.fileURL, UTType.plainText], isTargeted: $model.dropTargeted) { providers in
            model.handleDrop(providers)
        }
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1040, minHeight: 640)
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        let pauses = model.pauseAllPauses
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ListPresentation.title(selection: model.selection, search: model.searchText))
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(ListPresentation.subtitle(selection: model.selection, search: model.searchText, snapshot: model.snapshot))
                    .font(Typeface.ui(12.5).monospacedDigit())
                    .foregroundStyle(palette.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LinkBarView()
                .frame(minWidth: 200, idealWidth: 380, maxWidth: 380)

            Button {
                model.togglePauseAll()
            } label: {
                Image(systemName: pauses ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(RoundButtonStyle(kind: .glass, size: 42))
            .help(pauses ? "Pause all (⌥⌘P)" : "Resume all (⌥⌘P)")
            .accessibilityLabel(pauses ? "Pause all" : "Resume all")

            Button {
                model.openAddSheet()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
            }
            .buttonStyle(RoundButtonStyle(kind: .accent, size: 42))
            .help("Add downloads (⌘N)")
            .accessibilityLabel("Add downloads")
        }
        .padding(.top, 6)
        .padding(.leading, 12)
        .padding(.trailing, 2)
    }
}

// MARK: - Link bar

/// "Paste a link or search": a link shows what it is with Download now; anything else filters the list.
struct LinkBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        let isLink = model.linkURL != nil
        HStack(spacing: 9) {
            Image(systemName: isLink ? "link" : "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isLink ? palette.ink : palette.text3)
                .frame(width: 16)
            TextField("Paste a link or search", text: $model.linkText)
                .textFieldStyle(.plain)
                .font(Typeface.ui(13.5))
                .foregroundStyle(palette.text)
                .focused($focused)
                .onSubmit {
                    if model.linkURL != nil { model.downloadLinkNow() }
                }
                .onExitCommand {
                    model.linkText = ""
                    focused = false
                }
                .accessibilityLabel("Paste a link to download it, or type to search")
            KeyHint(text: "⌘K")
        }
        .padding(.leading, 15)
        .padding(.trailing, 8)
        .frame(height: 42)
        .glassPanel(radius: 21)
        .overlay(Capsule().strokeBorder(palette.text, lineWidth: 2).opacity(focused ? 1 : 0))
        .overlay(alignment: .topLeading) {
            if isLink {
                LinkPopoverView()
                    .offset(y: 50)
                    .transition(.opacity)
            }
        }
        .onChange(of: model.linkBarFocusRequest) { _, _ in
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            model.isEditingText = isFocused
        }
    }
}

private struct LinkPopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        let url = model.linkURL
        let inspection = model.linkInspection
        let name = inspection.flatMap { $0.failure == nil ? $0.fileName : nil } ?? url.map { FileNaming.suggestedName(url: $0) } ?? ""
        let size: String = {
            if let bytes = inspection?.size { return Format.size(bytes) }
            return inspection == nil ? "Checking…" : "Size unknown"
        }()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ExtensionTile(badge: badge(for: name), size: 40, radius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(Typeface.ui(13.5, .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(size) · \(model.displayFolder(forFileName: name))")
                        .font(Typeface.ui(12).monospacedDigit())
                        .foregroundStyle(palette.text2)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                Button("More options") { model.linkMoreOptions() }
                    .buttonStyle(PillButtonStyle(kind: .glass, height: 34, fullWidth: true))
                Button("Download now") { model.downloadLinkNow() }
                    .buttonStyle(PillButtonStyle(kind: .accent, height: 34, fullWidth: true))
            }
        }
        .padding(12)
        .frame(width: 380)
        .popPanel(radius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Download this link")
    }

    private func badge(for name: String) -> String {
        let ext = FileNaming.fileExtension(of: name)
        return ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(4))
    }
}

// MARK: - Banners

/// "Link on your clipboard" with Not now / Download.
struct ClipboardBannerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    let offer: ClipboardOffer

    var body: some View {
        let detail = [offer.name, offer.host].filter { !$0.isEmpty }.joined(separator: " · ")
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(palette.tint)
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: "doc.on.clipboard").font(.system(size: 16)).foregroundStyle(palette.inkOnTint))
            VStack(alignment: .leading, spacing: 2) {
                Text("Link on your clipboard")
                    .font(Typeface.ui(13, .semibold))
                    .foregroundStyle(palette.text)
                Text(detail)
                    .font(Typeface.ui(12).monospacedDigit())
                    .foregroundStyle(palette.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Not now") { model.dismissClipboardOffer() }
                .buttonStyle(PillButtonStyle(kind: .glass, height: 34))
            Button("Download") { model.acceptClipboardOffer() }
                .buttonStyle(PillButtonStyle(kind: .accent, height: 34, horizontalPadding: 16))
        }
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 9))
        .glassPanel(radius: 22)
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .accessibilityElement(children: .contain)
    }
}

/// "Ladle 1.1 is ready" with Restart to Update / Later.
struct UpdateBannerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var updates: UpdateController
    @Environment(\.palette) private var palette

    var body: some View {
        if let version = updates.readyVersion, !updates.bannerDismissed {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(palette.tint)
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: "arrow.down.circle").font(.system(size: 17)).foregroundStyle(palette.inkOnTint))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ladle \(version) is ready")
                        .font(Typeface.ui(13, .semibold))
                        .foregroundStyle(palette.text)
                    Text("Restart now, or it installs the next time Ladle quits.")
                        .font(Typeface.ui(12))
                        .foregroundStyle(palette.text2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Later") { updates.bannerDismissed = true }
                    .buttonStyle(PillButtonStyle(kind: .glass, height: 34))
                Button("Restart to Update") { updates.restartToUpdate(downloading: model.downloadingCount) }
                    .buttonStyle(PillButtonStyle(kind: .accent, height: 34, horizontalPadding: 16))
            }
            .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 9))
            .glassPanel(radius: 22)
            .padding(.leading, 4)
            .padding(.trailing, 2)
        }
    }
}
