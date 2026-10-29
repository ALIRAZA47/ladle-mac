import AppKit
import CoreText
import SwiftUI

extension Color {
    /// `0xRRGGBB` in sRGB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }

    init(r: Double, g: Double, b: Double, a: Double) {
        self.init(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}

/// The Molten tokens from the design (Main board `.lad` / `.lad.light`) and SPEC "Look".
struct Palette {
    let isDark: Bool

    let base: Color
    let glass: Color
    let pop: Color
    let highlight: Color
    let line: Color
    let line2: Color
    let button: Color
    let buttonHover: Color
    let hover: Color
    let text: Color
    let text2: Color
    let text3: Color
    let track: Color
    let steel: Color
    let danger: Color
    let dangerTint: Color
    let tile: Color
    let chip: Color
    let scrim: Color
    let shadow: Color
    /// Accent-colored text and icons.
    let ink: Color
    /// Accent text and icons on an orange tint (selected sidebar row, tinted tiles and cards).
    /// Darker than `ink` in light mode to keep 4.5:1 there.
    let inkOnTint: Color
    /// Accent wash behind icons and selected sidebar rows.
    let tint: Color
    let rowSelectedFill: Color

    static let accent = Color(hex: 0xFF8A1F)
    static let ember = Color(hex: 0xFF4F1A)
    static let glow = Color(hex: 0xFFC46B)
    static let onAccent = Color(hex: 0x1E1206)
    static let rowSelectedRing = Color(hex: 0xFF8A1F, opacity: 0.45)

    /// The pour: ember → molten → glow.
    static var pour: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: ember, location: 0),
                .init(color: accent, location: 0.55),
                .init(color: glow, location: 1),
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// The connection ring's gradient, bottom-left to top-right.
    static var ring: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: ember, location: 0),
                .init(color: accent, location: 0.55),
                .init(color: glow, location: 1),
            ]),
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }

    static let dark = Palette(
        isDark: true,
        base: Color(hex: 0x0C0B0A),
        glass: Color(r: 30, g: 28, b: 26, a: 0.58),
        pop: Color(r: 32, g: 30, b: 27, a: 0.96),
        highlight: Color(r: 255, g: 255, b: 255, a: 0.07),
        line: Color(r: 255, g: 240, b: 220, a: 0.09),
        line2: Color(r: 255, g: 240, b: 220, a: 0.15),
        button: Color(r: 52, g: 48, b: 44, a: 0.6),
        buttonHover: Color(r: 66, g: 61, b: 56, a: 0.75),
        hover: Color(r: 255, g: 244, b: 230, a: 0.05),
        text: Color(hex: 0xF6F2EC),
        text2: Color(hex: 0xB8B0A6),
        text3: Color(hex: 0x9C9489),
        track: Color(r: 255, g: 240, b: 220, a: 0.1),
        steel: Color(hex: 0xC9CDD3),
        danger: Color(hex: 0xFF6B5E),
        dangerTint: Color(r: 255, g: 107, b: 94, a: 0.16),
        tile: Color(r: 255, g: 244, b: 230, a: 0.06),
        chip: Color(hex: 0x2A2724),
        scrim: Color(r: 6, g: 5, b: 4, a: 0.55),
        shadow: Color(r: 0, g: 0, b: 0, a: 0.35),
        ink: Color(hex: 0xFF9A3D),
        inkOnTint: Color(hex: 0xFF9A3D),
        tint: Color(hex: 0xFF8A1F, opacity: 0.16),
        rowSelectedFill: Color(hex: 0xFF8A1F, opacity: 0.07)
    )

    static let light = Palette(
        isDark: false,
        base: Color(hex: 0xF3EFE9),
        glass: Color(r: 255, g: 255, b: 255, a: 0.6),
        pop: Color(r: 255, g: 255, b: 255, a: 0.97),
        highlight: Color(r: 255, g: 255, b: 255, a: 0.9),
        line: Color(r: 60, g: 40, b: 20, a: 0.1),
        line2: Color(r: 60, g: 40, b: 20, a: 0.16),
        button: Color(r: 255, g: 255, b: 255, a: 0.75),
        buttonHover: Color(r: 255, g: 255, b: 255, a: 0.95),
        hover: Color(r: 60, g: 40, b: 20, a: 0.045),
        text: Color(hex: 0x1A1714),
        text2: Color(hex: 0x554E46),
        text3: Color(hex: 0x675F57),
        track: Color(r: 60, g: 40, b: 20, a: 0.11),
        steel: Color(hex: 0x7B8491),
        danger: Color(hex: 0xC4321F),
        dangerTint: Color(r: 196, g: 50, b: 31, a: 0.1),
        tile: Color(r: 60, g: 40, b: 20, a: 0.05),
        chip: Color(hex: 0xFFFFFF),
        scrim: Color(r: 40, g: 30, b: 20, a: 0.25),
        shadow: Color(r: 60, g: 40, b: 20, a: 0.14),
        ink: Color(hex: 0xB4500E),
        inkOnTint: Color(hex: 0x9C440B),
        tint: Color(hex: 0xFF8A1F, opacity: 0.13),
        rowSelectedFill: Color(hex: 0xFF8A1F, opacity: 0.06)
    )

    static func forScheme(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = .dark
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Puts the palette for the current light/dark appearance into the environment.
struct Themed<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.environment(\.palette, Palette.forScheme(scheme))
    }
}

/// Type styles from the design: SF Pro for text, SF Pro Rounded for speeds and numbers,
/// Bricolage Grotesque for the wordmark.
enum Typeface {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }

    static let wordmarkName = "BricolageGrotesque96pt-ExtraBold"

    static func wordmark(_ size: CGFloat) -> Font {
        if NSFont(name: wordmarkName, size: size) != nil { return .custom(wordmarkName, size: size) }
        return .system(size: size, weight: .heavy, design: .rounded)
    }

    /// Makes the bundled wordmark font available to this process.
    static func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: "BricolageGrotesque-ExtraBold", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}
