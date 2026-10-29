import AppKit
import LadleKit
import SwiftUI

/// The menu bar item: the ladle glyph, plus the total speed while something downloads.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let speed = model.totalSpeed
        HStack(spacing: 4) {
            Image("MenuBarIcon")
            if model.downloadingCount > 0 && speed > 0 {
                Text(Format.speed(speed)).monospacedDigit()
            }
        }
        .accessibilityLabel(model.downloadingCount > 0 ? "Ladle, \(Format.speed(speed))" : "Ladle")
    }
}

/// The menu bar window: speed, clipboard suggestion, what's downloading, what's next.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        let downloading = model.items.filter { $0.status == .downloading }
        let upNext = Array(model.items.filter { $0.status == .queued }.prefix(4))
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Ladle")
                    .font(Typeface.wordmark(21))
                    .tracking(-0.6)
                    .foregroundStyle(palette.text)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                    Text(model.totalSpeed > 0 ? Format.speed(model.totalSpeed) : "Idle")
                }
                .font(Typeface.rounded(12))
                .foregroundStyle(palette.text2)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(palette.tile))
                Spacer()
                Button {
                    model.togglePauseAll()
                } label: {
                    Image(systemName: model.pauseAllPauses ? "pause.fill" : "play.fill").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(RoundButtonStyle(kind: .glass, size: 32))
                .accessibilityLabel(model.pauseAllPauses ? "Pause all" : "Resume all")
                Button {
                    model.openAddSheet()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(RoundButtonStyle(kind: .accent, size: 32))
                .accessibilityLabel("Add a download")
            }

            if let offer = model.clipboardOffer {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.clipboard").font(.system(size: 11))
                            Text("Link on your clipboard")
                        }
                        .font(Typeface.ui(12, .semibold))
                        .foregroundStyle(palette.inkOnTint)
                        Text(displayLink(offer.url))
                            .font(Typeface.mono(11.5))
                            .foregroundStyle(palette.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Download") { model.acceptClipboardOffer() }
                        .buttonStyle(PillButtonStyle(kind: .accent, height: 32, fontSize: 12.5))
                }
                .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10))
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.accent.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.accent.opacity(0.28), lineWidth: 1))
            }

            if !downloading.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Downloading · \(downloading.count)")
                    ForEach(downloading.prefix(5)) { item in
                        MenuBarRow(item: item)
                    }
                }
            }

            if !upNext.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Up next")
                    ForEach(upNext) { item in
                        UpNextRow(item: item)
                    }
                }
            }

            if downloading.isEmpty && upNext.isEmpty && model.clipboardOffer == nil {
                Text("Nothing downloading right now.")
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(palette.text3)
                    .padding(.vertical, 6)
            }

            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Toggle(isOn: $model.settings.limitSpeed) { EmptyView() }
                        .toggleStyle(MoltenSwitchStyle(width: 34, height: 20))
                        .accessibilityLabel("Limit speed")
                    Text("Limit speed")
                        .font(Typeface.ui(12.5))
                        .foregroundStyle(palette.text2)
                }
                Spacer()
                Button("Open Ladle") {
                    model.showMainWindow?()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(PillButtonStyle(kind: .glass, height: 32, fontSize: 12.5))
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        }
        .padding(16)
        .frame(width: 384)
        .background(AmbientBackground())
        .onAppear { model.clipboard.check(force: true) }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Typeface.ui(11.5, .semibold))
            .foregroundStyle(palette.text3)
            .padding(.bottom, 4)
    }

    private func displayLink(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        return text
    }
}

private struct MenuBarRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    let item: DownloadItem

    var body: some View {
        let live = model.live(item)
        let percent = item.fractionDone.map(Format.percent)
        let left = ItemPresentation.timeLeft(item, live: live).map(Format.eta)
        HStack(spacing: 10) {
            ExtensionTile(badge: ItemPresentation.extensionBadge(item), size: 32, radius: 10)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.fileName)
                        .font(Typeface.ui(12.5, .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text([percent, left].compactMap { $0 }.joined(separator: " · "))
                        .font(Typeface.rounded(11.5))
                        .foregroundStyle(palette.text2)
                        .fixedSize()
                }
                SegmentBar(segments: ItemPresentation.segments(item), height: 5, spacing: 2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedID = item.id
            model.showMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct UpNextRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    let item: DownloadItem

    var body: some View {
        let wait = model.waitReason(item)
        HStack(spacing: 10) {
            ExtensionTile(badge: ItemPresentation.extensionBadge(item), size: 32, radius: 10)
            Text(item.fileName)
                .font(Typeface.ui(12.5, .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                if case .tonight(let minute)? = wait {
                    Image(systemName: "moon").font(.system(size: 11))
                    Text("Tonight, \(TonightWindow.shortLabel(minute: minute))")
                } else if case .hold? = wait {
                    Text("Waiting")
                } else {
                    Text("Next")
                }
            }
            .font(Typeface.ui(11.5))
            .foregroundStyle(palette.text2)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(palette.tile))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }
}
