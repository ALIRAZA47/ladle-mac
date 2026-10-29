import LadleKit
import SwiftUI

/// The ladle glyph from the boards (24-unit box): a bowl, a handle, and an arrow pouring in.
struct LadleGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.minX + (rect.width - 24 * s) / 2
        let oy = rect.minY + (rect.height - 24 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        let k: CGFloat = 0.5523 * 6.5
        var path = Path()
        // Bowl: a flat rim from (3, 12.5) to (16, 12.5), then a half circle of radius 6.5 below it.
        path.move(to: p(3, 12.5))
        path.addLine(to: p(16, 12.5))
        path.addCurve(to: p(9.5, 19), control1: p(16, 12.5 + k), control2: p(9.5 + k, 19))
        path.addCurve(to: p(3, 12.5), control1: p(9.5 - k, 19), control2: p(3, 12.5 + k))
        path.closeSubpath()
        // Handle.
        path.move(to: p(16, 12.5))
        path.addLine(to: p(21, 5.5))
        // Arrow.
        path.move(to: p(9.5, 2.5))
        path.addLine(to: p(9.5, 8.5))
        path.move(to: p(7, 6.5))
        path.addLine(to: p(9.5, 9))
        path.addLine(to: p(12, 6.5))
        return path
    }
}

struct LadleGlyphView: View {
    var size: CGFloat = 16
    var lineWidth: CGFloat? = nil

    var body: some View {
        LadleGlyph()
            .stroke(style: StrokeStyle(lineWidth: lineWidth ?? size * 1.8 / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

extension FileCategory {
    /// SF Symbol for the category's tile and sidebar row.
    var symbol: String {
        switch self {
        case .video: return "film"
        case .music: return "music.note"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .apps: return "shippingbox"
        case .images: return "photo"
        case .other: return "doc"
        }
    }
}

/// A file's tile: category icon with the extension badge in the corner.
struct FileTile: View {
    @Environment(\.palette) private var palette
    let category: FileCategory
    let badge: String
    var size: CGFloat = 44
    var lit = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 14 / 44, style: .continuous)
            .fill(palette.tile)
            .overlay(RoundedRectangle(cornerRadius: size * 14 / 44, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
            .overlay(
                Image(systemName: category.symbol)
                    .font(.system(size: size * 0.4, weight: .regular))
                    .foregroundStyle(lit ? palette.ink : palette.text2)
            )
            .overlay(alignment: .bottomTrailing) {
                Text(badge)
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.3)
                    .foregroundStyle(palette.text2)
                    .padding(.horizontal, 4)
                    .frame(height: 16)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.chip))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
                    .offset(x: 5, y: 5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A plain extension tile (details header, add sheet rows, menu bar rows).
struct ExtensionTile: View {
    @Environment(\.palette) private var palette
    let badge: String
    var size: CGFloat = 40
    var radius: CGFloat = 12

    var body: some View {
        Text(badge)
            .font(.system(size: size >= 46 ? 10.5 : 9.5, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(palette.text2)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(palette.tile))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
            .accessibilityHidden(true)
    }
}
