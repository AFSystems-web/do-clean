import SwiftUI

/// Used/free disk ring: a dim track, a glowing gradient arc for the used part,
/// a hairline tick dial around it and the free amount in dot-matrix in the middle.
public struct DiskRing: View {
    public var used: Double
    public var total: Double
    public var palette: Palette
    public var lineWidth: CGFloat
    public var unit: String
    public var caption: String

    public init(used: Double, total: Double, palette: Palette = .system, lineWidth: CGFloat = 14,
                unit: String = "ГБ", caption: String = "свободно") {
        self.used = used
        self.total = total
        self.palette = palette
        self.lineWidth = lineWidth
        self.unit = unit
        self.caption = caption
    }

    var fraction: Double { total > 0 ? min(1, max(0, used / total)) : 0 }
    var free: Double { max(0, total - used) }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ringInset = lineWidth / 2 + 10
            ZStack {
                DialTicks(count: 72)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
                Circle()
                    .inset(by: ringInset)
                    .stroke(.white.opacity(0.07), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Glow under the arc.
                arc(inset: ringInset)
                    .blur(radius: lineWidth * 0.9)
                    .opacity(0.8)
                arc(inset: ringInset)
                VStack(spacing: 6) {
                    DotMatrixNumber(free, unit: unit, style: side > 280 ? .hero : (side > 170 ? .medium : .small))
                    Text(caption)
                        .font(Theme.Fonts.cardSubtitle)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(Theme.Motion.spring, value: used)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Свободно \(Int(free)) \(unit) из \(Int(total))"))
    }

    private func arc(inset: CGFloat) -> some View {
        Circle()
            .inset(by: inset)
            .trim(from: 0, to: fraction)
            .stroke(
                AngularGradient(
                    colors: [palette.secondary, palette.primary, palette.accent],
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle: .degrees(360 * max(fraction, 0.01))
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
    }
}

/// Radial tick marks on the outer edge of the ring.
private struct DialTicks: Shape {
    let count: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for i in 0..<count {
            let a = Double(i) / Double(count) * 2 * .pi - .pi / 2
            let long = i % 6 == 0
            let r0 = r - (long ? 6 : 3)
            p.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
            p.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
        }
        return p
    }
}
