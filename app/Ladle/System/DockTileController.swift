import AppKit

/// Overall progress drawn over the Dock icon, and a badge with how many are downloading.
@MainActor
final class DockTileController {
    private let view = DockProgressView()
    private var lastProgress: Double?
    private var lastBadge: Int = -1

    init() {
        view.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
    }

    /// - Parameters:
    ///   - progress: 0…1 across running downloads, or nil to show the plain icon.
    ///   - downloading: number of running downloads (no badge at zero).
    func update(progress: Double?, downloading: Int) {
        let tile = NSApp.dockTile
        if downloading != lastBadge {
            tile.badgeLabel = downloading > 0 ? String(downloading) : nil
            lastBadge = downloading
        }
        let rounded = progress.map { ($0 * 200).rounded() / 200 }
        guard rounded != lastProgress else { return }
        lastProgress = rounded
        if let rounded {
            view.progress = rounded
            if tile.contentView !== view { tile.contentView = view }
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}

/// The app icon with a molten progress bar along the bottom (Around the Mac board).
private final class DockProgressView: NSView {
    var progress: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let inset = bounds.width * 0.14
        let height = max(6, bounds.height * 0.085)
        let track = NSRect(x: inset, y: bounds.height * 0.12, width: bounds.width - inset * 2, height: height)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        trackPath.fill()
        NSColor.white.withAlphaComponent(0.15).setStroke()
        trackPath.lineWidth = 1
        trackPath.stroke()
        let fillWidth = max(height, track.width * CGFloat(min(1, max(0, progress))))
        let fill = NSRect(x: track.minX, y: track.minY, width: fillWidth, height: height)
        NSColor(srgbRed: 1, green: 138 / 255, blue: 31 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: fill, xRadius: height / 2, yRadius: height / 2).fill()
    }
}
