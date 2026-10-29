import LadleKit
import SwiftUI

// MARK: - Panels

/// Frosted glass panel: translucent fill, hairline border, a highlight along the top edge, soft shadow.
struct GlassPanel: ViewModifier {
    @Environment(\.palette) private var palette
    var radius: CGFloat
    var shadow: Bool = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(shape.fill(palette.glass))
            .overlay(shape.strokeBorder(palette.line, lineWidth: 1))
            .overlay(TopHighlight(radius: radius, color: palette.highlight))
            .clipShape(shape)
            .shadow(color: shadow ? palette.shadow : .clear, radius: 20, x: 0, y: 12)
    }
}

/// A popover-like panel, more opaque than glass.
struct PopPanel: ViewModifier {
    @Environment(\.palette) private var palette
    var radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(shape.fill(palette.pop))
            .overlay(shape.strokeBorder(palette.line2, lineWidth: 1))
            .overlay(TopHighlight(radius: radius, color: palette.highlight))
            .clipShape(shape)
            .shadow(color: Color.black.opacity(palette.isDark ? 0.4 : 0.16), radius: 30, x: 0, y: 24)
    }
}

/// The 1 px inner highlight at the top of glass surfaces (`inset 0 1px 0`).
struct TopHighlight: View {
    var radius: CGFloat
    var color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                LinearGradient(colors: [color, color.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.08)),
                lineWidth: 1
            )
            .allowsHitTesting(false)
    }
}

/// A quiet rounded area inside a panel (stats, the Source/Saved to list).
struct TileBox: ViewModifier {
    @Environment(\.palette) private var palette
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(shape.fill(palette.tile))
            .overlay(shape.strokeBorder(palette.line, lineWidth: 1))
    }
}

extension View {
    func glassPanel(radius: CGFloat, shadow: Bool = true) -> some View {
        modifier(GlassPanel(radius: radius, shadow: shadow))
    }

    func popPanel(radius: CGFloat) -> some View {
        modifier(PopPanel(radius: radius))
    }

    func tileBox(radius: CGFloat = 18) -> some View {
        modifier(TileBox(radius: radius))
    }
}

/// The window background: graphite (or paper) with a molten glow top-left and an ember glow bottom-right.
struct AmbientBackground: View {
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                palette.base
                RadialGradient(
                    colors: [Palette.accent.opacity(palette.isDark ? 0.2 : 0.17), Palette.accent.opacity(0)],
                    center: UnitPoint(x: 0.1, y: -0.12),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.48
                )
                RadialGradient(
                    colors: [Palette.ember.opacity(palette.isDark ? 0.13 : 0.09), Palette.ember.opacity(0)],
                    center: UnitPoint(x: 1.08, y: 1.12),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.42
                )
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Buttons

enum PillKind {
    case glass, accent, plain
}

/// Fully rounded buttons: glass (secondary) and molten (primary).
struct PillButtonStyle: ButtonStyle {
    var kind: PillKind = .glass
    var height: CGFloat = 34
    var horizontalPadding: CGFloat = 14
    var fontSize: CGFloat = 13
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, style: self)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: PillButtonStyle
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = Capsule(style: .continuous)
        let label = configuration.label
            .font(Typeface.ui(style.fontSize, style.kind == .accent ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, style.horizontalPadding)
            .frame(height: style.height)
            .frame(maxWidth: style.fullWidth ? .infinity : nil)
        return Group {
            switch style.kind {
            case .accent:
                label
                    .foregroundStyle(Palette.onAccent)
                    .background(shape.fill(Palette.accent))
                    .overlay(TopHighlight(radius: style.height / 2, color: Color.white.opacity(0.35)).clipShape(shape))
                    .shadow(color: Palette.accent.opacity(0.3), radius: 9, x: 0, y: 6)
                    .brightness(hovering && isEnabled ? 0.04 : 0)
            case .glass:
                label
                    .foregroundStyle(palette.text)
                    .background(shape.fill(hovering && isEnabled ? palette.buttonHover : palette.button))
                    .overlay(shape.strokeBorder(palette.line2, lineWidth: 1))
                    .overlay(TopHighlight(radius: style.height / 2, color: palette.highlight).clipShape(shape))
            case .plain:
                label
                    .foregroundStyle(palette.text2)
                    .background(shape.fill(hovering && isEnabled ? palette.hover : Color.clear))
            }
        }
        .contentShape(shape)
        .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
        .onHover { hovering = $0 }
    }
}

/// A round icon button (34 pt in rows, 42 pt in the header).
struct RoundButtonStyle: ButtonStyle {
    var kind: PillKind = .glass
    var size: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        RoundButtonBody(configuration: configuration, style: self)
    }
}

private struct RoundButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: RoundButtonStyle
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = Circle()
        let label = configuration.label.frame(width: style.size, height: style.size)
        return Group {
            if style.kind == .accent {
                label
                    .foregroundStyle(Palette.onAccent)
                    .background(shape.fill(Palette.accent))
                    .overlay(TopHighlight(radius: style.size / 2, color: Color.white.opacity(0.35)).clipShape(shape))
                    .shadow(color: Palette.accent.opacity(0.3), radius: 9, x: 0, y: 6)
                    .brightness(hovering && isEnabled ? 0.04 : 0)
            } else {
                label
                    .foregroundStyle(palette.text)
                    .background(shape.fill(hovering && isEnabled ? palette.buttonHover : palette.button))
                    .overlay(shape.strokeBorder(palette.line2, lineWidth: 1))
                    .overlay(TopHighlight(radius: style.size / 2, color: palette.highlight).clipShape(shape))
            }
        }
        .contentShape(shape)
        .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
        .onHover { hovering = $0 }
    }
}

/// A text-only link button in accent ink (Show/Hide, Change, Edit…).
struct InkButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 12.5

    func makeBody(configuration: Configuration) -> some View {
        InkButtonBody(configuration: configuration, fontSize: fontSize)
    }
}

private struct InkButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fontSize: CGFloat
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(Typeface.ui(fontSize, .semibold))
            .foregroundStyle(palette.ink)
            .underline(hovering)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

// MARK: - Switch

/// The pill switch from the design: molten track when on.
struct MoltenSwitchStyle: ToggleStyle {
    var width: CGFloat = 40
    var height: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        MoltenSwitchBody(configuration: configuration, width: width, height: height)
    }
}

private struct MoltenSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    let width: CGFloat
    let height: CGFloat
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let knob = height - 4
        HStack(spacing: 10) {
            configuration.label
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? Palette.accent : palette.track)
                    .frame(width: width, height: height)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: Color.black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                    .padding(2)
            }
            .animation(.easeOut(duration: 0.2), value: configuration.isOn)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Segmented

/// A pill segmented control (Now / Tonight, Auto / Light / Dark).
struct PillSegmented<Value: Hashable>: View {
    @Environment(\.palette) private var palette
    @Binding var selection: Value
    let options: [(Value, String)]
    var height: CGFloat = 30

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let value = options[index].0
                let on = value == selection
                Button {
                    selection = value
                } label: {
                    Text(options[index].1)
                        .font(Typeface.ui(12.5, .medium))
                        .foregroundStyle(on ? palette.text : palette.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .background(
                            Capsule(style: .continuous)
                                .fill(on ? palette.buttonHover : Color.clear)
                                .shadow(color: on ? Color.black.opacity(0.2) : .clear, radius: 1.5, x: 0, y: 1)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(palette.tile))
        .overlay(Capsule(style: .continuous).strokeBorder(palette.line, lineWidth: 1))
    }
}

// MARK: - Small pieces

/// The rounded count next to sidebar items and group titles.
struct CountBadge: View {
    @Environment(\.palette) private var palette
    let count: Int
    var danger = false
    var height: CGFloat = 20

    var body: some View {
        Text(String(count))
            .font(Typeface.ui(11.5, .semibold).monospacedDigit())
            .foregroundStyle(danger ? palette.danger : palette.text3)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: height)
            .background(Capsule().fill(danger ? palette.dangerTint : palette.tile))
    }
}

/// Status chips in rows: Paused, Tonight, Verified, Failed…
struct StatusChip: View {
    @Environment(\.palette) private var palette
    let chip: Chip

    var body: some View {
        Text(chip.text)
            .font(Typeface.ui(11, .semibold))
            .foregroundStyle(chip.style == .danger ? palette.danger : palette.text2)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(chip.style == .danger ? palette.dangerTint : palette.tile))
            .fixedSize()
    }
}

/// The ⌘K hint in the link bar.
struct KeyHint: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        Text(text)
            .font(Typeface.ui(11.5))
            .foregroundStyle(palette.text3)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(palette.tile))
            .overlay(Capsule().strokeBorder(palette.line, lineWidth: 1))
    }
}
