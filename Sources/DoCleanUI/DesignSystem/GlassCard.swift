import SwiftUI

/// Rounded glass card (28 pt) with an inner colored `MeshBlur`,
/// a semibold title, a translucent subtitle on the second line,
/// optional top-trailing icon and a footer slot. Hover lifts it, press sinks it.
public struct GlassCard<Content: View, Footer: View>: View {
    let title: String?
    let subtitle: String?
    let systemImage: String?
    let palette: Palette?
    let focus: MeshBlurFocus
    let glow: Double
    let animated: Bool
    let action: (() -> Void)?
    let content: Content
    let footer: Footer

    public init(
        _ title: String? = nil,
        subtitle: String? = nil,
        systemImage: String? = nil,
        palette: Palette? = nil,
        focus: MeshBlurFocus = .bottomTrailing,
        glow: Double = 1,
        animated: Bool = true,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.palette = palette
        self.focus = focus
        self.glow = glow
        self.animated = animated
        self.action = action
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        if let action {
            Button(action: action) { CardBody(card: self, pressed: false) }
                .buttonStyle(GlassCardButtonStyle(card: self))
        } else {
            CardBody(card: self, pressed: false)
        }
    }
}

public extension GlassCard where Footer == EmptyView {
    init(
        _ title: String? = nil,
        subtitle: String? = nil,
        systemImage: String? = nil,
        palette: Palette? = nil,
        focus: MeshBlurFocus = .bottomTrailing,
        glow: Double = 1,
        animated: Bool = true,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, palette: palette, focus: focus,
                  glow: glow, animated: animated, action: action, content: content, footer: { EmptyView() })
    }
}

private struct GlassCardButtonStyle<Content: View, Footer: View>: ButtonStyle {
    let card: GlassCard<Content, Footer>
    func makeBody(configuration: Configuration) -> some View {
        CardBody(card: card, pressed: configuration.isPressed)
    }
}

private struct CardBody<Content: View, Footer: View>: View {
    let card: GlassCard<Content, Footer>
    let pressed: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if card.title != nil || card.systemImage != nil {
                header
            }
            card.content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            if !(card.footer is EmptyView) {
                card.footer
                    .font(Theme.Fonts.footer)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.top, Theme.Spacing.m)
            }
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                Theme.Colors.cardBase
                if let palette = card.palette {
                    MeshBlur(palette, focus: card.focus, intensity: card.glow * (hovering ? 1.08 : 1), animated: card.animated)
                }
                // Glass sheen: light from the top edge, a touch of frost.
                LinearGradient(
                    colors: [.white.opacity(0.09), .white.opacity(0.015), .clear],
                    startPoint: .top, endPoint: .center
                )
                // Keep the title zone legible.
                LinearGradient(
                    colors: [.black.opacity(0.28), .clear],
                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)
                )
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(hovering ? 0.30 : 0.20), .white.opacity(0.04), .white.opacity(0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .shadow(color: (card.palette?.primary ?? .black).opacity(hovering ? 0.22 : 0.10), radius: hovering ? 28 : 18, y: 8)
        .scaleEffect(pressed ? 0.975 : (hovering && card.action != nil ? 1.012 : 1))
        .animation(Theme.Motion.snappy, value: pressed)
        .animation(Theme.Motion.spring, value: hovering)
        .onHover { hovering = $0 }
        .contentShape(shape)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                if let title = card.title {
                    Text(title)
                        .font(Theme.Fonts.cardTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                }
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(Theme.Fonts.cardSubtitle)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let systemImage = card.systemImage {
                GlassIcon(systemImage: systemImage)
            }
        }
    }
}

/// Small round glass button-like icon used at card corners.
public struct GlassIcon: View {
    let systemImage: String
    let size: CGFloat

    public init(systemImage: String, size: CGFloat = 32) {
        self.systemImage = systemImage
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: size, height: size)
            .background(Circle().fill(.white.opacity(0.10)))
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }
}
