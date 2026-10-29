import LadleKit
import SwiftUI

/// The grouped list: Downloading, Paused, Up next, Needs attention, Completed today.
struct DownloadListView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        let groups = model.groups
        let selectedID = model.selectedItem?.id
        Group {
            if groups.isEmpty {
                EmptyStateView()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            GroupHeaderView(group: group)
                            ForEach(group.items) { item in
                                DownloadRowView(item: item, selected: item.id == selectedID)
                                    .id(item.id)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.automatic)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            model.toggleSelected()
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
    }
}

private struct GroupHeaderView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    let group: ItemGroup

    var body: some View {
        HStack(spacing: 8) {
            Text(group.kind.label)
                .font(Typeface.ui(12.5, .semibold))
                .foregroundStyle(palette.text2)
                .accessibilityAddTraits(.isHeader)
            CountBadge(count: group.count, height: 18)
            Spacer(minLength: 0)
            if group.isCollapsible {
                Button(group.isCollapsed ? "Show" : "Hide") {
                    model.showCompleted.toggle()
                }
                .buttonStyle(InkButtonStyle())
                .accessibilityValue(group.isCollapsed ? "Collapsed" : "Expanded")
            }
        }
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 4, trailing: 12))
        .frame(minHeight: 36)
    }
}

/// One download: file tile, name and chip, the segmented bar, the meta line, speed and an action.
struct DownloadRowView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    let item: DownloadItem
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let live = model.live(item)
        let wait = model.waitReason(item)
        let chip = ItemPresentation.chip(item, wait: wait)
        HStack(spacing: 14) {
            FileTile(category: item.category, badge: ItemPresentation.extensionBadge(item), size: 44, lit: item.status == .downloading)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(item.fileName)
                        .font(Typeface.ui(14, .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let chip { StatusChip(chip: chip) }
                }
                SegmentBar(segments: ItemPresentation.segments(item))
                Text(ItemPresentation.meta(item, live: live, wait: wait, settings: model.settings, now: model.snapshot.date))
                    .font(Typeface.ui(12.5).monospacedDigit())
                    .foregroundStyle(ItemPresentation.metaIsDanger(item) ? palette.danger : palette.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Text(ItemPresentation.speedText(item, live: live))
                    .font(Typeface.rounded(14, .semibold))
                    .foregroundStyle(palette.text)
                    .frame(minWidth: 78, alignment: .trailing)
                RowActionButton(item: item)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(selected ? palette.rowSelectedFill : (hovering ? palette.hover : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? Palette.rowSelectedRing : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            if item.status == .completed { model.open(item) }
        }
        .simultaneousGesture(TapGesture().onEnded { model.selectedID = item.id })
        .contextMenu { RowContextMenu(item: item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Show details") { model.selectedID = item.id }
    }
}

private struct RowActionButton: View {
    @EnvironmentObject private var model: AppModel
    let item: DownloadItem

    var body: some View {
        switch item.status {
        case .downloading:
            button("pause.fill", "Pause", 11) { model.pause(item.id) }
        case .paused:
            button("play.fill", item.neverStarted ? "Start" : "Resume", 11) { model.resume(item.id) }
        case .queued:
            button("play.fill", "Start now", 11) { model.startNow(item.id) }
        case .failed:
            if item.failure?.needsStartOver == true {
                button("arrow.counterclockwise", "Start over", 13) { model.startOver(item.id) }
            } else {
                button("arrow.clockwise", "Retry", 13) { model.retry(item.id) }
            }
        case .completed:
            button("magnifyingglass", "Show in Finder", 13) { model.reveal(item) }
        }
    }

    private func button(_ symbol: String, _ label: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
        }
        .buttonStyle(RoundButtonStyle(kind: .glass, size: 34))
        .help(label)
        .accessibilityLabel("\(label) \(item.fileName)")
    }
}

/// The same actions as the Downloads menu, for a right-click.
struct RowContextMenu: View {
    @EnvironmentObject private var model: AppModel
    let item: DownloadItem

    var body: some View {
        switch item.status {
        case .downloading, .queued:
            Button("Pause") { model.pause(item.id) }
            if item.status == .queued { Button("Start Now") { model.startNow(item.id) } }
        case .paused:
            Button(item.neverStarted ? "Start" : "Resume") { model.resume(item.id) }
        case .failed:
            if item.failure?.needsStartOver == true {
                Button("Start Over") { model.startOver(item.id) }
            } else {
                Button("Retry") { model.retry(item.id) }
            }
        case .completed:
            Button("Open") { model.open(item) }
        }
        Button("Show in Finder") { model.reveal(item) }
        Button("Copy Link") { model.copyLink(item) }
        Divider()
        Button("Remove from List") { model.remove(item.id) }
    }
}

/// "No downloads yet": a dashed drop target with the ladle and Add a download.
struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            LadleGlyphView(size: 44, lineWidth: 2)
                .foregroundStyle(palette.ink)
            Text(ListPresentation.emptyTitle(selection: model.selection, search: model.searchText))
                .font(Typeface.ui(18, .bold))
                .foregroundStyle(palette.text)
            Text("Copy a link and paste it in the bar above, or drop it anywhere on this window. Ladle sorts it into the right folder for you.")
                .font(Typeface.ui(13))
                .foregroundStyle(palette.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 340)
            Button("Add a download") { model.openAddSheet() }
                .buttonStyle(PillButtonStyle(kind: .accent, height: 36, horizontalPadding: 18))
                .padding(.top, 4)
        }
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(palette.line2, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .padding(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
    }
}
