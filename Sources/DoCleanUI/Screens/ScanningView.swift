import SwiftUI
import DoCleanCore

/// Live scan: found-bytes counter, running tick scale, cards filling per category.
struct ScanningView: View {
    @Bindable var model: AppModel

    var body: some View {
        let scan = model.scan
        let g = Theme.Metrics.gridSpacing
        VStack(spacing: g) {
            GlassCard(nil, palette: .system, focus: .trailing, glow: 0.35 + 0.65 * scan.progress, animated: model.animated) {
                HStack(alignment: .center, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Найдено").font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
                        let d = ByteDisplay(scan.bytesFound, gigabytes: 1)
                        DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .hero)
                            .animation(Theme.Motion.spring, value: scan.bytesFound)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Сканирую · \(model.mode.title)")
                                .font(Theme.Fonts.cardTitle).foregroundStyle(.white)
                            Spacer()
                            DotMatrixText("\(scan.completedRules)/\(max(scan.totalRules, model.rulesForMode.count))", style: .small)
                        }
                        RunningScale(progress: scan.progress, animated: model.animated)
                        Text(currentText)
                            .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    PillButton("Отменить", systemImage: "xmark") { model.cancelScan() }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 170)

            GeometryReader { geo in
                let col = (geo.size.width - g * 2) / 3
                let rowH = (geo.size.height - g) / 2
                VStack(spacing: g) {
                    HStack(spacing: g) {
                        ForEach(dashboardCategories.prefix(3), id: \.self) { LiveCategoryCard(model: model, category: $0).frame(width: col) }
                    }
                    .frame(height: rowH)
                    HStack(spacing: g) {
                        ForEach(dashboardCategories.suffix(2), id: \.self) { LiveCategoryCard(model: model, category: $0).frame(width: col) }
                        TierTotalsCard(model: model).frame(width: col)
                    }
                    .frame(height: rowH)
                }
            }
        }
    }

    private var currentText: String {
        let titles = model.rules.filter { model.scan.currentRuleIDs.contains($0.id) }.map { $0.title.ru }
        return titles.isEmpty ? "Готовлю список мест…" : "Смотрю: " + titles.joined(separator: ", ")
    }
}

/// Tick scale whose marker follows progress; a soft highlight sweeps while it runs.
struct RunningScale: View {
    let progress: Double
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TickScale(value: progress, tickCount: 61, accentEvery: 10, color: .white, leadingLabel: "0", trailingLabel: "100", height: 22)
            .animation(Theme.Motion.spring, value: progress)
            .overlay {
                if animated && !reduceMotion {
                    TimelineView(.animation) { t in
                        let phase = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        GeometryReader { geo in
                            LinearGradient(colors: [.clear, Palette.system.accent.opacity(0.55), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 70)
                                .offset(x: phase * (geo.size.width + 70) - 70)
                                .blendMode(.plusLighter)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

struct LiveCategoryCard: View {
    @Bindable var model: AppModel
    let category: RuleCategory

    var body: some View {
        let rules = model.rulesForMode.filter { $0.category == category }
        let done = rules.compactMap { model.scan.resultsByRule[$0.id] }
        let bytes = done.reduce(Int64(0)) { $0 + $1.bytes }
        let active = rules.contains { model.scan.currentRuleIDs.contains($0.id) }
        let fraction = rules.isEmpty ? 1 : Double(done.count) / Double(rules.count)
        GlassCard(category.shortTitle, subtitle: category.subtitle, systemImage: category.systemImage,
                  palette: category.palette, glow: rules.isEmpty ? 0.15 : 0.25 + 0.75 * fraction, animated: model.animated) {
            VStack(alignment: .leading, spacing: 12) {
                if rules.isEmpty {
                    DotMatrixText("--", style: .large.dimmed)
                } else {
                    let d = ByteDisplay(bytes, gigabytes: 1)
                    DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .large)
                        .animation(Theme.Motion.count, value: bytes)
                }
                TickScale(value: fraction, tickCount: 31, color: .white, height: 16)
                    .animation(Theme.Motion.spring, value: fraction)
            }
        } footer: {
            HStack(spacing: 6) {
                if rules.isEmpty {
                    Text("не в этом режиме")
                } else if fraction >= 1 {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.safe)
                    Text("Готово · \(plural(done.filter { !$0.items.isEmpty }.count, "находка", "находки", "находок"))")
                } else {
                    if active { Circle().fill(Palette.system.accent).frame(width: 6, height: 6).shadow(color: Palette.system.accent, radius: 4) }
                    Text("\(done.count) из \(rules.count)")
                }
            }
        }
    }
}

struct TierTotalsCard: View {
    @Bindable var model: AppModel

    var body: some View {
        let results = Array(model.scan.resultsByRule.values)
        GlassCard("По уровням", subtitle: "Что уже нашлось", systemImage: "shield.lefthalf.filled", animated: model.animated) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Tier.allCases, id: \.self) { tier in
                    let b = results.filter { $0.rule.tier == tier }.reduce(Int64(0)) { $0 + $1.bytes }
                    HStack {
                        TierBadge(tier.badge)
                        Spacer()
                        let d = ByteDisplay(b, gigabytes: 1)
                        DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .small)
                            .opacity(model.mode.tiers.contains(tier) ? 1 : 0.3)
                    }
                }
            }
        }
    }
}
