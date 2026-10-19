import SwiftUI

/// Thin tick-mark scale with taller accent ticks, a small triangle marker
/// and optional end labels ("−" / "+", "0" / "100"). Value in 0…1, animates with springs.
public struct TickScale: View {
    public var value: Double
    public var tickCount: Int
    public var accentEvery: Int
    public var color: Color
    public var leadingLabel: String?
    public var trailingLabel: String?
    public var height: CGFloat

    public init(
        value: Double,
        tickCount: Int = 41,
        accentEvery: Int = 5,
        color: Color = .white,
        leadingLabel: String? = nil,
        trailingLabel: String? = nil,
        height: CGFloat = 22
    ) {
        self.value = value
        self.tickCount = max(2, tickCount)
        self.accentEvery = max(1, accentEvery)
        self.color = color
        self.leadingLabel = leadingLabel
        self.trailingLabel = trailingLabel
        self.height = height
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let leadingLabel { label(leadingLabel) }
            TickScaleCanvas(value: min(1, max(0, value)), tickCount: tickCount, accentEvery: accentEvery, color: color)
                .frame(height: height)
            if let trailingLabel { label(trailingLabel) }
        }
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((value * 100).rounded())) %"))
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(color.opacity(0.55))
            .monospacedDigit()
    }
}

private struct TickScaleCanvas: View, @preconcurrency Animatable {
    var value: Double
    let tickCount: Int
    let accentEvery: Int
    let color: Color

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let markerH: CGFloat = 5
            let tickTop = markerH + 3
            let tickZone = size.height - tickTop
            let stepX = (size.width - 1) / CGFloat(tickCount - 1)
            let markerX = CGFloat(value) * (size.width - 1) + 0.5
            for i in 0..<tickCount {
                let x = CGFloat(i) * stepX + 0.5
                let accent = i % accentEvery == 0
                let h = accent ? tickZone : tickZone * 0.55
                let passed = x <= markerX + 0.5
                let opacity = passed ? (accent ? 0.95 : 0.7) : (accent ? 0.35 : 0.18)
                let rect = CGRect(x: x - 0.5, y: size.height - h, width: 1, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(color.opacity(opacity)))
            }
            // Triangle marker pointing down at the value.
            var tri = Path()
            tri.move(to: CGPoint(x: markerX - 4, y: 0))
            tri.addLine(to: CGPoint(x: markerX + 4, y: 0))
            tri.addLine(to: CGPoint(x: markerX, y: markerH + 1))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(color))
        }
    }
}
