import LadleKit
import SwiftUI

/// The details panel: the connection ring (one arc per connection), stats, where it came from
/// and where it goes, and the actions.
struct DetailsPanelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let item = model.selectedItem {
                DetailsContent(item: item)
            } else {
                Text("Pick a download to see its connections and details.")
                    .font(Typeface.ui(13))
                    .foregroundStyle(palette.text3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .glassPanel(radius: 24)
    }
}

private struct DetailsContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    let item: DownloadItem

    var body: some View {
        let live = model.live(item)
        let details = ItemPresentation.details(item, live: live, wait: model.waitReason(item), settings: model.settings, now: model.snapshot.date)
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                ExtensionTile(badge: ItemPresentation.extensionBadge(item), size: 48, radius: 15)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.fileName)
                        .font(Typeface.ui(14.5, .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Image(systemName: item.url.scheme == "https" ? "lock" : "globe")
                            .font(.system(size: 10))
                        Text(item.host)
                            .lineLimit(1)
                    }
                    .font(Typeface.ui(12))
                    .foregroundStyle(palette.text2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ZStack {
                ConnectionRing(arcs: details.arcs, diameter: 184)
                VStack(spacing: 4) {
                    Text(details.center)
                        .font(Typeface.rounded(40, .bold))
                        .tracking(-1.2)
                        .foregroundStyle(details.centerIsDanger ? palette.danger : palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: 130)
                    Text(details.centerSub)
                        .font(Typeface.ui(12).monospacedDigit())
                        .foregroundStyle(palette.text2)
                }
            }
            .frame(width: 184, height: 184)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(details.ringLabel)

            HStack(spacing: 6) {
                ForEach(details.stats.indices, id: \.self) { index in
                    let stat = details.stats[index]
                    VStack(spacing: 3) {
                        Text(stat.label)
                            .font(Typeface.ui(11))
                            .foregroundStyle(palette.text3)
                        Text(stat.value)
                            .font(Typeface.rounded(15, .semibold))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .tileBox(radius: 18)

            Text(details.note)
                .font(Typeface.ui(12))
                .foregroundStyle(details.noteIsDanger ? palette.danger : palette.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                InfoRow(label: "Source") {
                    HStack(spacing: 6) {
                        Text(item.url.absoluteString)
                            .font(Typeface.mono(11.5))
                            .foregroundStyle(palette.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Button {
                            model.copyLink(item)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10.5))
                        }
                        .buttonStyle(RoundButtonStyle(kind: .glass, size: 26))
                        .help("Copy link")
                        .accessibilityLabel("Copy link")
                    }
                }
                InfoRow(label: "Saved to") {
                    Text(Destination.displayPath(item.directory))
                        .foregroundStyle(palette.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                InfoRow(label: "Added") {
                    Text(Format.added(item.addedAt, now: model.snapshot.date))
                        .foregroundStyle(palette.text2)
                }
            }
            .font(Typeface.ui(12))
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .tileBox(radius: 18)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(details.primary.title) { model.perform(details.primary, on: item) }
                    .buttonStyle(PillButtonStyle(kind: details.primary == .pause ? .glass : .accent, height: 38, fullWidth: true))
                Button("Show in Finder") { model.reveal(item) }
                    .buttonStyle(PillButtonStyle(kind: .glass, height: 38, horizontalPadding: 12, fullWidth: true))
                Button {
                    model.remove(item.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 13))
                }
                .buttonStyle(RoundButtonStyle(kind: .glass, size: 38))
                .help("Remove from list (the file stays)")
                .accessibilityLabel("Remove from list")
            }
        }
    }
}

private struct InfoRow<Value: View>: View {
    @Environment(\.palette) private var palette
    let label: String
    let value: Value

    init(label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(palette.text3)
                .frame(width: 62, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
