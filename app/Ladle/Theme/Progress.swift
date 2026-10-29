import LadleKit
import SwiftUI

/// A download's bar: one segment per connection that glows while pouring, dims when paused,
/// and becomes a single steel bar when finished.
struct SegmentBar: View {
    @Environment(\.palette) private var palette
    let segments: [SegmentState]
    var height: CGFloat = 7
    var spacing: CGFloat = 3

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(segments.indices, id: \.self) { index in
                SegmentView(segment: segments[index], height: height)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct SegmentView: View {
    @Environment(\.palette) private var palette
    let segment: SegmentState
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * CGFloat(min(1, max(0, segment.fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                if width > 0.5 {
                    fill
                        .frame(width: max(width, height))
                        .clipShape(Capsule())
                        .shadow(color: segment.isLive ? Palette.accent.opacity(0.55) : .clear, radius: 5)
                        .overlay(alignment: .trailing) {
                            if segment.isLive { PourSpark(height: height) }
                        }
                }
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.5), value: segment.fraction)
    }

    @ViewBuilder
    private var fill: some View {
        switch segment.style {
        case .finished:
            Capsule().fill(palette.steel)
        case .failed:
            Capsule().fill(palette.danger).opacity(0.6)
        case .paused:
            Capsule().fill(Palette.pour).opacity(0.45)
        case .pouring, .waiting:
            Capsule().fill(Palette.pour)
        }
    }
}

/// The flicker at the leading edge of a pouring segment.
private struct PourSpark: View {
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.8)], startPoint: .leading, endPoint: .trailing))
            .frame(width: min(12, height * 1.7), height: height)
            .opacity(reduceMotion ? 0.6 : (bright ? 0.95 : 0.25))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { bright = true }
            }
            .allowsHitTesting(false)
    }
}

/// The connection ring in the details panel: one arc per connection, filling as its piece pours in.
struct ConnectionRing: View {
    @Environment(\.palette) private var palette
    let arcs: [SegmentState]
    var diameter: CGFloat = 184
    var lineWidth: CGFloat = 12

    var body: some View {
        let count = max(1, arcs.count)
        let radius = diameter / 2 - 14
        let circumference = 2 * CGFloat.pi * radius
        let slot = 1 / CGFloat(count)
        let gap = count == 1 ? 0 : 18 / circumference
        let span = max(4 / circumference, slot - gap)
        return ZStack {
            ForEach(arcs.indices, id: \.self) { index in
                let start = CGFloat(index) * slot + (slot - span) / 2
                let arc = arcs[index]
                let fraction = CGFloat(min(1, max(0, arc.fraction)))
                ZStack {
                    Circle()
                        .trim(from: start, to: start + span)
                        .stroke(palette.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    if fraction > 0.002 {
                        if arc.isLive {
                            Circle()
                                .trim(from: start, to: start + span * fraction)
                                .stroke(Palette.ring, style: StrokeStyle(lineWidth: lineWidth * 2, lineCap: .round))
                                .opacity(0.22)
                        }
                        Circle()
                            .trim(from: start, to: start + span * fraction)
                            .stroke(arcStyle(arc), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                            .opacity(arcOpacity(arc))
                    }
                }
                .frame(width: radius * 2, height: radius * 2)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: fraction)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func arcStyle(_ arc: SegmentState) -> AnyShapeStyle {
        switch arc.style {
        case .finished: return AnyShapeStyle(palette.steel)
        case .failed: return AnyShapeStyle(palette.danger)
        default: return AnyShapeStyle(Palette.ring)
        }
    }

    private func arcOpacity(_ arc: SegmentState) -> Double {
        switch arc.style {
        case .failed: return 0.8
        case .paused: return 0.45
        default: return 1
        }
    }
}

/// The speed card's sparkline: the last 48 seconds of total speed.
struct Sparkline: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let top = max(samples.max() ?? 0, 1_000_000) * 1.15
            let points: [CGPoint] = samples.enumerated().map { index, value in
                let x = samples.count > 1 ? CGFloat(index) / CGFloat(samples.count - 1) * size.width : 0
                let y = size.height - 2 - CGFloat(value / top) * (size.height - 4)
                return CGPoint(x: x, y: y)
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: size.height))
                    for point in points { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: size.height))
                    path.closeSubpath()
                }
                .fill(Palette.accent.opacity(0.16))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
