import SwiftUI

/// Look of a dot-matrix run: dot size, spacing, colors.
public struct DotMatrixStyle: Sendable, Equatable {
    public enum DotShape: Sendable, Equatable { case circle, roundedSquare }

    public var dotSize: CGFloat
    public var spacing: CGFloat
    public var color: Color
    /// Opacity of unlit cells (0 hides them). A faint grid reads as "LED panel".
    public var offOpacity: Double
    /// Soft bloom behind lit dots.
    public var glow: Double
    public var shape: DotShape

    public init(
        dotSize: CGFloat = 4,
        spacing: CGFloat = 1.6,
        color: Color = .white,
        offOpacity: Double = 0.035,
        glow: Double = 0.4,
        shape: DotShape = .circle
    ) {
        self.dotSize = dotSize
        self.spacing = spacing
        self.color = color
        self.offOpacity = offOpacity
        self.glow = glow
        self.shape = shape
    }

    var pitch: CGFloat { dotSize + spacing }

    /// Half-size variant for units next to a number.
    func unitStyle(color: Color) -> DotMatrixStyle {
        var s = self
        s.dotSize = max(1.4, dotSize * 0.5)
        s.spacing = max(0.6, spacing * 0.5)
        s.color = color
        s.offOpacity = 0
        s.glow = glow * 0.5
        return s
    }

    public static let hero = DotMatrixStyle(dotSize: 6, spacing: 2.2)
    public static let large = DotMatrixStyle(dotSize: 4.6, spacing: 1.8)
    public static let medium = DotMatrixStyle(dotSize: 3.2, spacing: 1.3)
    public static let small = DotMatrixStyle(dotSize: 2.2, spacing: 0.9, offOpacity: 0.025, glow: 0.3)
}

// MARK: - Layout

/// Positions of lit cells for a string, measured in columns from the right edge,
/// so two strings of different lengths cross-fade aligned to the right.
struct DotMatrixLayout {
    /// Total width in columns (glyph columns plus one gap column between glyphs).
    let columns: Int
    /// Lit cells: (column from left, row).
    let lit: [(col: Int, row: Int)]
    /// All glyph cells (lit or not), for drawing the faint "off" grid.
    let cells: [(col: Int, row: Int)]

    init(_ text: String) {
        var col = 0
        var lit: [(Int, Int)] = []
        var cells: [(Int, Int)] = []
        let glyphs = text.compactMap(DotMatrixFont.glyph(for:))
        for (i, g) in glyphs.enumerated() {
            for r in 0..<DotMatrixFont.rows {
                for c in 0..<g.width {
                    cells.append((col + c, r))
                    if g.isLit(row: r, column: c) { lit.append((col + c, r)) }
                }
            }
            col += g.width + (i < glyphs.count - 1 ? 1 : 0)
        }
        columns = col
        self.lit = lit
        self.cells = cells
    }

    static func size(columns: Int, style: DotMatrixStyle) -> CGSize {
        guard columns > 0 else { return CGSize(width: 0, height: CGFloat(DotMatrixFont.rows) * style.pitch - style.spacing) }
        return CGSize(
            width: CGFloat(columns) * style.pitch - style.spacing,
            height: CGFloat(DotMatrixFont.rows) * style.pitch - style.spacing
        )
    }
}

// MARK: - Static text

/// Draws a string with the 5×7 dot font. Unknown characters are skipped.
/// `from`/`progress` cross-fade cell by cell from another string.
public struct DotMatrixText: View {
    let text: String
    let from: String?
    let progress: Double
    let style: DotMatrixStyle
    let minColumns: Int

    public init(_ text: String, style: DotMatrixStyle = .large) {
        self.init(text, from: nil, progress: 1, style: style, minColumns: 0)
    }

    init(_ text: String, from: String?, progress: Double, style: DotMatrixStyle, minColumns: Int) {
        self.text = text
        self.from = from
        self.progress = progress
        self.style = style
        self.minColumns = minColumns
    }

    public var body: some View {
        let target = DotMatrixLayout(text)
        let source = from.map(DotMatrixLayout.init)
        let columns = max(minColumns, target.columns, source?.columns ?? 0)
        let size = DotMatrixLayout.size(columns: columns, style: style)
        Canvas { ctx, canvasSize in
            draw(in: &ctx, columns: columns, target: target, source: source)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement()
        .accessibilityLabel(Text(text))
    }

    private func draw(in ctx: inout GraphicsContext, columns: Int, target: DotMatrixLayout, source: DotMatrixLayout?) {
        let pitch = style.pitch
        // Accumulate per-cell intensity, right-aligned.
        var intensity: [Int: Double] = [:]
        func key(_ col: Int, _ row: Int) -> Int { row * 10_000 + col }
        let tShift = columns - target.columns
        let t = source == nil ? 1 : progress
        for cell in target.lit { intensity[key(cell.col + tShift, cell.row), default: 0] += t }
        if let source {
            let sShift = columns - source.columns
            for cell in source.lit { intensity[key(cell.col + sShift, cell.row), default: 0] += 1 - t }
        }

        func rect(_ col: Int, _ row: Int, grow: CGFloat = 0) -> CGRect {
            CGRect(x: CGFloat(col) * pitch - grow, y: CGFloat(row) * pitch - grow,
                   width: style.dotSize + grow * 2, height: style.dotSize + grow * 2)
        }
        func path(_ r: CGRect) -> Path {
            switch style.shape {
            case .circle: Path(ellipseIn: r)
            case .roundedSquare: Path(roundedRect: r, cornerRadius: r.width * 0.28)
            }
        }

        // Faint off grid: smaller dots so it never reads as a solid grey block on bright cards.
        if style.offOpacity > 0 {
            var off = Path()
            let shrink = style.dotSize * 0.22
            for cell in target.cells {
                let col = cell.col + tShift
                if (intensity[key(col, cell.row)] ?? 0) > 0.01 { continue }
                off.addPath(path(rect(col, cell.row).insetBy(dx: shrink, dy: shrink)))
            }
            ctx.fill(off, with: .color(style.color.opacity(style.offOpacity)))
        }

        // Bloom.
        if style.glow > 0 {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: style.dotSize * 0.6))
                for (k, v) in intensity where v > 0.01 {
                    let r = rect(k % 10_000, k / 10_000)
                    layer.fill(path(r), with: .color(style.color.opacity(min(1, v) * style.glow)))
                }
            }
        }

        // Crisp dots.
        for (k, v) in intensity where v > 0.01 {
            ctx.fill(path(rect(k % 10_000, k / 10_000)), with: .color(style.color.opacity(min(1, v))))
        }
    }
}

// MARK: - Animated number

/// How the unit next to a number is shown.
public enum DotMatrixUnitStyle: Sendable, Equatable {
    /// Small dot-matrix letters (`ГБ`, `MB`…).
    case dots
    /// SF Pro label.
    case label
}

/// A number drawn in dot-matrix that counts up/down to new values; dots fade cell by cell.
/// Width is reserved for the target value, so the number does not jitter while counting.
public struct DotMatrixNumber: View {
    public var value: Double
    public var decimals: Int
    public var prefix: String
    public var suffix: String
    public var unit: String?
    public var unitStyle: DotMatrixUnitStyle
    public var style: DotMatrixStyle
    public var unitColor: Color?

    public init(
        _ value: Double,
        decimals: Int = 0,
        prefix: String = "",
        suffix: String = "",
        unit: String? = nil,
        unitStyle: DotMatrixUnitStyle = .dots,
        style: DotMatrixStyle = .large,
        unitColor: Color? = nil
    ) {
        self.value = value
        self.decimals = decimals
        self.prefix = prefix
        self.suffix = suffix
        self.unit = unit
        self.unitStyle = unitStyle
        self.style = style
        self.unitColor = unitColor
    }

    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: style.pitch * 2) {
            AnimatedDigits(
                value: value,
                target: value,
                decimals: decimals,
                prefix: prefix,
                suffix: suffix,
                style: style
            )
            .alignmentGuide(.lastTextBaseline) { d in d[.bottom] }
            if let unit {
                unitView(unit)
                    .alignmentGuide(.lastTextBaseline) { d in d[.bottom] }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(DotMatrixNumber.format(value, decimals: decimals, prefix: prefix, suffix: suffix) + (unit.map { " " + $0 } ?? "")))
    }

    @ViewBuilder private func unitView(_ unit: String) -> some View {
        let color = unitColor ?? style.color.opacity(0.6)
        switch unitStyle {
        case .dots:
            DotMatrixText(unit, style: style.unitStyle(color: color))
        case .label:
            Text(unit)
                .font(.system(size: max(11, style.pitch * 3.2), weight: .semibold))
                .foregroundStyle(color)
        }
    }

    /// Formats like the Russian locale: comma decimals, thin grouping for ≥ 10 000.
    public static func format(_ value: Double, decimals: Int, prefix: String = "", suffix: String = "") -> String {
        let negative = value < 0
        let factor = pow(10, Double(decimals))
        let rounded = (abs(value) * factor).rounded() / factor
        let intPart = Int(rounded)
        var intString = String(intPart)
        if intPart >= 10_000 {
            var grouped = ""
            for (i, ch) in intString.reversed().enumerated() {
                if i > 0 && i % 3 == 0 { grouped.append(" ") }
                grouped.append(ch)
            }
            intString = String(grouped.reversed())
        }
        var s = intString
        if decimals > 0 {
            let frac = Int(((rounded - Double(intPart)) * factor).rounded())
            let fracString = String(frac)
            s += "," + String(repeating: "0", count: max(0, decimals - fracString.count)) + fracString
        }
        return (negative ? "-" : "") + prefix + s + suffix
    }
}

/// Animatable core: interpolates the value, renders the two neighbouring
/// representable numbers and cross-fades them by the fractional step.
private struct AnimatedDigits: View, @preconcurrency Animatable {
    var value: Double
    /// Not animated: the final value, used to reserve width.
    let target: Double
    let decimals: Int
    let prefix: String
    let suffix: String
    let style: DotMatrixStyle

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let step = pow(10, -Double(decimals))
        let lower = (value / step).rounded(.down) * step
        let fraction = min(1, max(0, (value - lower) / step))
        let reserve = DotMatrixLayout(DotMatrixNumber.format(target, decimals: decimals, prefix: prefix, suffix: suffix)).columns
        if fraction < 0.001 || abs(value - target) < step * 0.001 {
            DotMatrixText(DotMatrixNumber.format(abs(value - target) < step * 0.001 ? target : lower, decimals: decimals, prefix: prefix, suffix: suffix),
                          from: nil, progress: 1, style: style, minColumns: reserve)
        } else {
            DotMatrixText(
                DotMatrixNumber.format(lower + step, decimals: decimals, prefix: prefix, suffix: suffix),
                from: DotMatrixNumber.format(lower, decimals: decimals, prefix: prefix, suffix: suffix),
                progress: fraction,
                style: style,
                minColumns: reserve
            )
        }
    }
}
