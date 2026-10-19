import SwiftUI

/// Capsule glass button. `selected` turns it into a solid white pill (segmented modes).
public struct PillButton: View {
    let title: String
    let systemImage: String?
    let selected: Bool
    let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, selected: Bool = false, action: @escaping () -> Void = {}) {
        self.title = title
        self.systemImage = systemImage
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(Theme.Fonts.button)
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .buttonStyle(PillStyle(selected: selected))
    }
}

private struct PillStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.black : .white.opacity(0.92))
            .background(
                Capsule().fill(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(hovering ? 0.14 : 0.08)))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0 : 0.14), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
            .animation(Theme.Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Segmented row of pills (Быстро / Глубоко / Всё).
public struct PillPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    public init(_ options: [(Value, String)], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                PillButton(title, selected: value == selection) {
                    withAnimation(Theme.Motion.spring) { selection = value }
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// The big primary "Сканировать" button: a glowing mesh-filled capsule.
public struct PrimaryScanButton: View {
    let title: String
    let subtitle: String?
    let palette: Palette
    let animated: Bool
    let action: () -> Void

    public init(_ title: String = "Сканировать", subtitle: String? = nil, palette: Palette = .system,
                animated: Bool = true, action: @escaping () -> Void = {}) {
        self.title = title
        self.subtitle = subtitle
        self.palette = palette
        self.animated = animated
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12, weight: .medium)).opacity(0.7)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.black.opacity(0.25)))
            }
            .foregroundStyle(.white)
            .padding(.leading, 24)
            .padding(.trailing, 10)
            .frame(height: 60)
        }
        .buttonStyle(PrimaryStyle(palette: palette, animated: animated))
    }
}

private struct PrimaryStyle: ButtonStyle {
    let palette: Palette
    let animated: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                ZStack {
                    LinearGradient(colors: [palette.deep, palette.primary, palette.secondary],
                                   startPoint: .leading, endPoint: .trailing)
                    MeshBlur(palette, focus: .trailing, intensity: 0.55, animated: animated)
                        .blendMode(.screen)
                    LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center)
                }
                .clipShape(Capsule())
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
            .shadow(color: palette.primary.opacity(hovering ? 0.65 : 0.45), radius: hovering ? 26 : 18, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.015 : 1))
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
            .animation(Theme.Motion.spring, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Safety tier badge: green «Безопасно», yellow «Проверь», red «Личное».
public struct TierBadge: View {
    public enum Kind: String, CaseIterable, Sendable {
        case safe, review, personal

        public var title: String {
            switch self {
            case .safe: "Безопасно"
            case .review: "Проверь"
            case .personal: "Личное"
            }
        }

        public var color: Color {
            switch self {
            case .safe: Theme.Colors.safe
            case .review: Theme.Colors.review
            case .personal: Theme.Colors.personal
            }
        }

        public var systemImage: String {
            switch self {
            case .safe: "checkmark.shield.fill"
            case .review: "eye.fill"
            case .personal: "lock.fill"
            }
        }
    }

    let kind: Kind
    let compact: Bool

    public init(_ kind: Kind, compact: Bool = false) {
        self.kind = kind
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(kind.color)
                .frame(width: 6, height: 6)
                .shadow(color: kind.color.opacity(0.9), radius: 4)
            if !compact {
                Text(kind.title)
                    .font(Theme.Fonts.badge)
            }
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, compact ? 6 : 9)
        .frame(height: 22)
        // Dark glass so the badge reads on any vivid mesh.
        .background(Capsule().fill(.black.opacity(0.42)))
        .background(Capsule().fill(kind.color.opacity(0.10)))
        .overlay(Capsule().strokeBorder(kind.color.opacity(0.45), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(kind.title))
    }
}
