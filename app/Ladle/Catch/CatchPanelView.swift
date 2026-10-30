import LadleKit
import SwiftUI

/// The three stages from the Catch board.
struct CatchPanelView: View {
    @EnvironmentObject private var controller: CatchPanelController
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch controller.stage {
            case .ask(let request)?:
                AskCard(request: request)
            case .pouring(let id)?:
                if let item = model.item(id) { PouringPill(item: item) }
            case .done(let id)?:
                if let item = model.item(id) { DonePill(item: item) }
            case nil:
                EmptyView()
            }
        }
        .frame(width: 380)
        .padding(20)
    }
}

private struct BrandMark: View {
    @Environment(\.palette) private var palette
    var size: CGFloat
    var circle = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: circle ? size / 2 : size / 3, style: .continuous)
        shape
            .fill(palette.tint)
            .frame(width: size, height: size)
            .overlay(LadleGlyphView(size: size * 0.5).foregroundStyle(palette.inkOnTint))
    }
}

private struct AskCard: View {
    @EnvironmentObject private var controller: CatchPanelController
    @Environment(\.palette) private var palette
    let request: CatchRequest

    var body: some View {
        let inspection = controller.inspection
        let name = inspection.flatMap { $0.failure == nil ? $0.fileName : nil } ?? request.request.initialName
        let ext = FileNaming.fileExtension(of: name)
        let size = inspection?.size ?? request.request.size
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BrandMark(size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trusted ? "Ladle caught a download" : "A web page asked Ladle to download")
                        .font(Typeface.ui(14, .semibold))
                        .foregroundStyle(palette.text)
                    Text(source)
                        .font(Typeface.ui(12))
                        .foregroundStyle(palette.text2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    controller.close()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(RoundButtonStyle(kind: .glass, size: 30))
                .accessibilityLabel("Dismiss")
            }

            HStack(spacing: 12) {
                FileTile(category: FileCategory.forFileName(name), badge: ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(4)), size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(Typeface.ui(13.5, .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if trusted {
                        HStack(spacing: 6) {
                            Text(size.map(Format.size) ?? (inspection == nil ? "Checking…" : "Size unknown"))
                            if inspection?.resumable == true {
                                Text("·")
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                    Text("Resumable")
                                }
                                .foregroundStyle(palette.ink)
                            }
                        }
                        .font(Typeface.ui(12).monospacedDigit())
                        .foregroundStyle(palette.text2)
                    } else {
                        // The page chose this address; show it, so the person knows what they're approving.
                        Text(request.request.url.absoluteString)
                            .font(Typeface.ui(12).monospacedDigit())
                            .foregroundStyle(palette.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
            .tileBox(radius: 18)

            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(palette.ink)
                Text(controller.folderLine(for: request))
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(palette.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Change") { controller.chooseFolder() }
                    .buttonStyle(InkButtonStyle())
            }
            .padding(.horizontal, 4)

            if trusted && !ext.isEmpty {
                Toggle(isOn: $controller.alwaysForType) {
                    Text("Always download .\(ext) files without asking")
                        .font(Typeface.ui(12.5))
                        .foregroundStyle(palette.text2)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 4)
            }

            HStack(spacing: 8) {
                Button("Let the browser handle it") { controller.answerBrowser() }
                    .buttonStyle(PillButtonStyle(kind: .plain, height: 34, horizontalPadding: 6, fontSize: 12.5))
                Spacer(minLength: 4)
                Button("Later") { controller.answerLater() }
                    .buttonStyle(PillButtonStyle(kind: .glass, height: 34, horizontalPadding: 15))
                    .help("Adds it to your list without starting it")
                Button("Download") { controller.answerDownload() }
                    .buttonStyle(PillButtonStyle(kind: .accent, height: 34, horizontalPadding: 17))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .popPanel(radius: 24)
    }

    /// Whether a browser Ladle knows handed this over. A web page's link gets no say over what the card claims.
    private var trusted: Bool { request.origin.isTrusted }

    private var source: String {
        let site = request.site
        if let browser = request.browserName, !browser.isEmpty, browser != "your browser" {
            return site.isEmpty ? "From \(browser)" : "From \(site) in \(browser)"
        }
        return site.isEmpty ? "From your browser" : "From \(site)"
    }
}

private struct PouringPill: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var controller: CatchPanelController
    @Environment(\.palette) private var palette
    let item: DownloadItem

    var body: some View {
        let live = model.live(item)
        let percent = item.fractionDone.map(Format.percent)
        let speed = Format.speed(live?.speed ?? 0)
        HStack(spacing: 12) {
            BrandMark(size: 34, circle: true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.fileName)
                        .font(Typeface.ui(13, .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(percent.map { "\($0) · \(speed)" } ?? speed)
                        .font(Typeface.rounded(12))
                        .foregroundStyle(palette.text2)
                        .fixedSize()
                }
                SegmentBar(segments: ItemPresentation.segments(item), height: 5, spacing: 2)
            }
            Button {
                model.pause(item.id)
                controller.close()
            } label: {
                Image(systemName: "pause.fill").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(RoundButtonStyle(kind: .glass, size: 32))
            .accessibilityLabel("Pause")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 64)
        .popPanel(radius: 32)
    }
}

private struct DonePill: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var controller: CatchPanelController
    @Environment(\.palette) private var palette
    let item: DownloadItem

    var body: some View {
        let size = Format.size(item.totalBytes ?? item.receivedBytes)
        let detail = item.activeDuration >= 1 ? "\(size) in \(Format.duration(item.activeDuration))" : size
        HStack(spacing: 12) {
            Circle()
                .fill(palette.steel)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Color(hex: 0x141312)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(Typeface.ui(13, .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(Typeface.rounded(12))
                    .foregroundStyle(palette.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Show in Finder") {
                model.reveal(item)
                controller.close()
            }
            .buttonStyle(PillButtonStyle(kind: .glass, height: 32, horizontalPadding: 12, fontSize: 12.5))
            Button("Open") {
                model.open(item)
                controller.close()
            }
            .buttonStyle(PillButtonStyle(kind: .accent, height: 32, horizontalPadding: 14, fontSize: 12.5))
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 64)
        .popPanel(radius: 32)
    }
}
