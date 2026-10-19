import SwiftUI
import AppKit

/// Component gallery: a dashboard-like grid with fake numbers.
/// Launch the app with `-gallery` to see it, `-snapshot <path.png>` to render it offscreen.
public struct GalleryView: View {
    /// False for snapshots: no count-up from zero, no breathing.
    let animated: Bool

    @State private var mode = 1
    @State private var bump = false
    @State private var appeared: Bool

    public init(animated: Bool = true) {
        self.animated = animated
        _appeared = State(initialValue: !animated)
    }

    public static let canvasSize = CGSize(width: 1320, height: 904)

    // Fake data. `bump` re-rolls it to show the count animation.
    private var adobe: Double { appeared ? (bump ? 38 : 46) : 0 }
    private var xcode: Double { appeared ? (bump ? 31 : 24) : 0 }
    private var ai: Double { appeared ? (bump ? 12 : 10) : 0 }
    private var downloads: Double { appeared ? (bump ? 9 : 14) : 0 }
    private var used: Double { appeared ? (bump ? 702 : 788) : 0 }

    public var body: some View {
        let g = Theme.Metrics.gridSpacing
        VStack(alignment: .leading, spacing: 22) {
            header
            HStack(spacing: g) {
                freeSpaceCard.frame(width: wide)
                categoryCard("After Effects", "Кэши / After Effects", value: adobe, palette: .adobe,
                             icon: "film.stack", tier: .safe, note: "Когда AE закрыт")
                categoryCard("Xcode", "DerivedData / Симуляторы", value: xcode, palette: .xcode,
                             icon: "hammer.fill", tier: .safe, note: "Пересоберётся само")
            }
            .frame(height: 272)
            HStack(spacing: g) {
                categoryCard("AI-модели", "Ollama / LM Studio", value: ai, palette: .ai,
                             icon: "brain.head.profile", tier: .review, note: "Скачаются заново")
                categoryCard("Загрузки", "Старше 90 дней", value: downloads, palette: .downloads,
                             icon: "arrow.down.circle.fill", tier: .review, note: "214 файлов", focus: .bottomLeading)
                metricsCard.frame(width: wide)
            }
            .frame(height: 236)
            HStack(spacing: g) {
                smallCard("Личное", "Документы / Фото", value: 3.2, palette: .personal, tier: .personal)
                smallCard("Корзина", "1 248 объектов", value: 1.8, palette: .trash, tier: .safe)
                controlsCard.frame(width: wide)
            }
            .frame(height: 214)
        }
        .padding(Theme.Metrics.screenPadding)
        .frame(minWidth: Self.canvasSize.width, minHeight: Self.canvasSize.height, alignment: .topLeading)
        .background(Theme.Colors.background)
        .preferredColorScheme(.dark)
        .onAppear {
            guard animated, !appeared else { return }
            withAnimation(Theme.Motion.count.delay(0.15)) { appeared = true }
        }
    }

    private var wide: CGFloat {
        let inner = Self.canvasSize.width - Theme.Metrics.screenPadding * 2 - Theme.Metrics.gridSpacing * 3
        return inner / 2 + Theme.Metrics.gridSpacing / 2
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text("do clean").font(Theme.Fonts.screenTitle).foregroundStyle(.white)
                Text("Компоненты / дизайн-система").font(.system(size: 14)).foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
            PillPicker([(0, "Быстро"), (1, "Глубоко"), (2, "Всё")], selection: $mode)
            DotMatrixText("09:50", style: .medium)
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(Capsule().fill(.white.opacity(0.05)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        }
    }

    // MARK: Cards

    private var freeSpaceCard: some View {
        GlassCard("Macintosh HD", subtitle: "Свободное место", systemImage: "internaldrive.fill",
                  palette: .system, focus: .bottomLeading, glow: 0.9, animated: animated) {
            HStack(alignment: .center, spacing: 28) {
                DiskRing(used: used, total: 1000, palette: .system)
                    .frame(width: 196, height: 196)
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Можно освободить").font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
                        DotMatrixNumber(adobe + xcode + ai + downloads, unit: "ГБ", style: .hero)
                    }
                    TickScale(value: (adobe + xcode + ai + downloads) / 120, color: Palette.system.accent,
                              leadingLabel: "0", trailingLabel: "120")
                    HStack(spacing: 6) {
                        TierBadge(.safe)
                        TierBadge(.review)
                        TierBadge(.personal)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func categoryCard(_ title: String, _ subtitle: String, value: Double, palette: Palette,
                              icon: String, tier: TierBadge.Kind, note: String,
                              focus: MeshBlurFocus = .bottomTrailing) -> some View {
        GlassCard(title, subtitle: subtitle, systemImage: icon, palette: palette, focus: focus,
                  animated: animated, action: { withAnimation(Theme.Motion.count) { bump.toggle() } }) {
            VStack(alignment: .leading, spacing: 14) {
                DotMatrixNumber(value, unit: "ГБ", style: .hero)
                TickScale(value: value / 60, tickCount: 31, color: .white, height: 18)
            }
        } footer: {
            HStack {
                TierBadge(tier)
                Spacer()
                Text(note).lineLimit(1)
            }
        }
    }

    private func smallCard(_ title: String, _ subtitle: String, value: Double, palette: Palette,
                           tier: TierBadge.Kind) -> some View {
        GlassCard(title, subtitle: subtitle, palette: palette, focus: .bottomTrailing, glow: 0.85, animated: animated) {
            HStack(alignment: .bottom) {
                DotMatrixNumber(value, decimals: 1, unit: "ГБ", style: .large)
                Spacer()
                TierBadge(tier)
            }
        }
    }

    private var metricsCard: some View {
        GlassCard("Today's Metrix", subtitle: "Шкалы / Точечные цифры", palette: .ai, focus: .trailing,
                  glow: 0.75, animated: animated) {
            HStack(alignment: .bottom, spacing: 22) {
                metric("Температура", DotMatrixText("23°", style: .large), value: 0.46, labels: ("−", "+"))
                metric("Кэши", DotMatrixText("45%", style: .large), value: 0.45, labels: ("0", "100"))
                metric("Последняя чистка", DotMatrixText("09:50", style: .large), value: 0.4, labels: nil)
            }
        }
    }

    private func metric<V: View>(_ title: String, _ number: V, value: Double, labels: (String, String)?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
            number
            TickScale(value: value, tickCount: 25, accentEvery: 4, color: .white,
                      leadingLabel: labels?.0, trailingLabel: labels?.1, height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controlsCard: some View {
        GlassCard("Сканирование", subtitle: "Кнопки / Режимы", systemImage: "slider.horizontal.3", animated: animated) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    PillButton("Отчёт", systemImage: "doc.text")
                    PillButton("Исключения", systemImage: "nosign")
                    PillButton("История", systemImage: "clock")
                }
                PrimaryScanButton("Сканировать", subtitle: "Глубокий режим · ~40 с", palette: .system, animated: animated) {
                    withAnimation(Theme.Motion.count) { bump.toggle() }
                }
            }
        }
    }
}

// MARK: - Snapshot

/// Renders `GalleryView` offscreen to PNG (used by the app's `-snapshot <path>` flag).
public enum GallerySnapshot {
    public enum Failure: Error { case render, encode }

    @MainActor
    public static func render(to url: URL, scale: CGFloat = 2) throws {
        let view = GalleryView(animated: false)
            .frame(width: GalleryView.canvasSize.width, height: GalleryView.canvasSize.height)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = true
        guard let cg = renderer.cgImage else { throw Failure.render }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure.encode }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
