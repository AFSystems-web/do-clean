import SwiftUI

/// Where the glow of a card sits. The reference cards keep the top dark for the title
/// and let the color bloom from one corner.
public enum MeshBlurFocus: Sendable, Equatable {
    case bottomTrailing, bottomLeading, bottom, center, trailing
}

/// Soft colored mesh glow inside a card: `MeshGradient` on macOS 15+,
/// blurred-blob Canvas on macOS 14. Breathes slowly; still under Reduce Motion.
public struct MeshBlur: View {
    let palette: Palette
    let focus: MeshBlurFocus
    let intensity: Double
    let animated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ palette: Palette, focus: MeshBlurFocus = .bottomTrailing, intensity: Double = 1, animated: Bool = true) {
        self.palette = palette
        self.focus = focus
        self.intensity = intensity
        self.animated = animated
    }

    public var body: some View {
        let still = !animated || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { timeline in
            let phase = still ? 0.0 : timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / Theme.Motion.breathPeriod
            ZStack {
                if #available(macOS 15.0, *) {
                    MeshLayer(palette: palette, focus: focus, phase: phase)
                } else {
                    BlobLayer(palette: palette, focus: focus, phase: phase)
                }
                // Extra bloom on top so the brightest spot glows instead of being flat.
                BloomSpot(palette: palette, focus: focus, phase: phase)
            }
            .opacity(intensity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared geometry

private extension MeshBlurFocus {
    /// Unit-space center of the hot spot.
    var hotSpot: CGPoint {
        switch self {
        case .bottomTrailing: CGPoint(x: 0.82, y: 0.92)
        case .bottomLeading: CGPoint(x: 0.18, y: 0.92)
        case .bottom: CGPoint(x: 0.5, y: 1.0)
        case .center: CGPoint(x: 0.5, y: 0.62)
        case .trailing: CGPoint(x: 1.0, y: 0.55)
        }
    }
}

private func wobble(_ phase: Double, _ k: Double, _ amp: Double) -> Double {
    sin(phase * k + k * 1.7) * amp
}

// MARK: - macOS 15+: MeshGradient

@available(macOS 15.0, *)
private struct MeshLayer: View {
    let palette: Palette
    let focus: MeshBlurFocus
    let phase: Double

    var body: some View {
        let base = Theme.Colors.cardBase
        let deep = palette.deep
        let p = palette.primary
        let s = palette.secondary
        let hot = focus.hotSpot

        // 4×4 mesh. Colors fall off with distance from the hot spot:
        // near → primary/secondary, mid → deep, far → card base.
        var points: [SIMD2<Float>] = []
        var colors: [Color] = []
        for row in 0..<4 {
            for col in 0..<4 {
                var x = Double(col) / 3
                var y = Double(row) / 3
                let interior = col > 0 && col < 3 && row > 0 && row < 3
                if interior {
                    x += wobble(phase, Double(row * 4 + col) * 0.37 + 1, 0.06)
                    y += wobble(phase, Double(row * 4 + col) * 0.29 + 0.6, 0.05)
                }
                points.append(SIMD2(Float(x), Float(y)))
                let d = hypot(Double(col) / 3 - hot.x, Double(row) / 3 - hot.y)
                let alt = (row + col) % 2 == 0
                let c: Color
                switch d {
                case ..<0.3: c = alt ? p : s
                case ..<0.6: c = alt ? s : p.mix(deep, 0.35)
                case ..<0.9: c = deep
                default: c = base
                }
                colors.append(c)
            }
        }
        return MeshGradient(width: 4, height: 4, points: points, colors: colors, smoothsColors: true)
            .blur(radius: 18)
            .scaleEffect(1.15)
    }
}

// MARK: - macOS 14: blurred blobs

private struct BlobLayer: View {
    let palette: Palette
    let focus: MeshBlurFocus
    let phase: Double

    var body: some View {
        Canvas { ctx, size in
            let hot = focus.hotSpot
            let m = max(size.width, size.height)
            ctx.addFilter(.blur(radius: m * 0.16))
            func blob(_ c: Color, _ ux: Double, _ uy: Double, _ r: Double) {
                let rect = CGRect(x: ux * size.width - r * m / 2, y: uy * size.height - r * m / 2, width: r * m, height: r * m)
                ctx.fill(Path(ellipseIn: rect), with: .color(c))
            }
            blob(palette.deep, hot.x, hot.y, 1.5)
            blob(palette.secondary, hot.x - 0.28 + wobble(phase, 1.1, 0.05), hot.y - 0.12, 0.75)
            blob(palette.primary, hot.x + wobble(phase, 0.8, 0.06), hot.y + wobble(phase, 1.3, 0.04), 0.7)
        }
    }
}

// MARK: - Bloom

private struct BloomSpot: View {
    let palette: Palette
    let focus: MeshBlurFocus
    let phase: Double

    var body: some View {
        GeometryReader { geo in
            let hot = focus.hotSpot
            let m = max(geo.size.width, geo.size.height)
            let breath = 1 + wobble(phase, 1, 0.06)
            RadialGradient(
                colors: [palette.accent.opacity(0.55), palette.primary.opacity(0.35), .clear],
                center: UnitPoint(x: hot.x, y: hot.y),
                startRadius: 0,
                endRadius: m * 0.42 * breath
            )
            .blendMode(.plusLighter)
            .opacity(0.55)
        }
    }
}

extension Color {
    /// Linear mix in sRGB, `t` = share of `other`.
    func mix(_ other: Color, _ t: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        return Color(.sRGB,
                     red: a.redComponent * (1 - t) + b.redComponent * t,
                     green: a.greenComponent * (1 - t) + b.greenComponent * t,
                     blue: a.blueComponent * (1 - t) + b.blueComponent * t,
                     opacity: a.alphaComponent * (1 - t) + b.alphaComponent * t)
    }
}
