import LadleKit
import SwiftUI

/// The floating glass sidebar: Library, Categories, Queues, and the speed card.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Room for the window's traffic lights, which sit inside the panel.
            Color.clear.frame(height: 18)

            SidebarSection(title: "Library") {
                NavRow(selection: .all, symbol: "tray", badge: .pill)
                NavRow(selection: .active, symbol: "arrow.down.circle", badge: .pill)
                NavRow(selection: .queued, symbol: "clock", badge: .pill)
                NavRow(selection: .completed, symbol: "checkmark.circle", badge: .pill)
                NavRow(selection: .failed, symbol: "exclamationmark.triangle", badge: .alert)
            }
            SidebarSection(title: "Categories") {
                ForEach(FileCategory.sorted, id: \.self) { category in
                    NavRow(selection: .category(category), symbol: category.symbol, badge: .plain)
                }
            }
            SidebarSection(title: "Queues") {
                NavRow(selection: .queue(.main), symbol: "line.3.horizontal", badge: .plain)
                NavRow(selection: .queue(.tonight), symbol: "moon", badge: .time(TonightWindow.shortLabel(minute: model.settings.tonightStartMinute)))
            }
            Spacer(minLength: 0)
            SpeedCardView()
        }
        .padding(EdgeInsets(top: 14, leading: 10, bottom: 10, trailing: 10))
        .glassPanel(radius: 22)
    }
}

private struct SidebarSection<Content: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Typeface.ui(11.5, .semibold))
                .foregroundStyle(palette.text3)
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private enum NavBadge {
    case pill, alert, plain
    case time(String)
}

private struct NavRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    let selection: LibrarySelection
    let symbol: String
    let badge: NavBadge
    @State private var hovering = false

    var body: some View {
        let on = model.selection == selection
        let count = model.count(selection)
        Button {
            model.selection = selection
            if model.linkURL == nil { model.linkText = "" }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(on ? palette.inkOnTint : palette.text2)
                    .frame(width: 18)
                Text(selection.title)
                    .font(Typeface.ui(13.5))
                    .foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch badge {
                case .pill:
                    CountBadge(count: count)
                case .alert:
                    CountBadge(count: count, danger: count > 0)
                case .plain:
                    Text(String(count))
                        .font(Typeface.ui(12).monospacedDigit())
                        .foregroundStyle(palette.text3)
                case .time(let label):
                    Text(label)
                        .font(Typeface.ui(11, .semibold))
                        .foregroundStyle(palette.text3)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(palette.tile))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? palette.tint : (hovering ? palette.hover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Total speed, the last minute as a sparkline, and the speed limit switch.
struct SpeedCardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        let speed = model.totalSpeed
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Speed")
                    .font(Typeface.ui(11.5, .semibold))
                    .foregroundStyle(palette.text2)
                Spacer()
                Text(model.settings.limitSpeed ? "capped" : "no limit")
                    .font(Typeface.ui(11.5))
                    .foregroundStyle(palette.text3)
            }
            Text(speed > 0 ? Format.speed(speed) : "Idle")
                .font(Typeface.rounded(28, .bold))
                .tracking(-0.5)
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Sparkline(samples: model.snapshot.speedHistory)
                .frame(height: 40)
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.text2)
                Text("Limit to \(Format.speedLimit(model.settings.speedLimitBytesPerSecond))")
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(palette.text2)
                Spacer(minLength: 4)
                Toggle(isOn: $model.settings.limitSpeed) { EmptyView() }
                    .toggleStyle(MoltenSwitchStyle(width: 34, height: 20))
                    .accessibilityLabel("Limit total speed")
            }
            .frame(height: 32)
            .padding(.horizontal, 4)
        }
        .padding(14)
        .tileBox(radius: 18)
    }
}
