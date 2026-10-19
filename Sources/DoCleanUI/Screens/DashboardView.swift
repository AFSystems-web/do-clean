import SwiftUI
import DoCleanCore

/// Switches between the stages of the home flow.
struct HomeFlowView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            switch model.stage {
            case .dashboard: DashboardView(model: model).transition(.opacity)
            case .scanning: ScanningView(model: model).transition(.opacity)
            case .results: ResultsView(model: model).transition(.opacity)
            case .cleaning: CleaningView(model: model).transition(.opacity)
            case .finished: FinishedView(model: model).transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.bottom, Theme.Metrics.screenPadding)
    }
}

/// Cards shown on the dashboard and the scanning screen, in order.
let dashboardCategories: [RuleCategory] = [.creative, .dev, .ai, .system, .personal]

// MARK: - Dashboard

struct DashboardView: View {
    @Bindable var model: AppModel

    var body: some View {
        let g = Theme.Metrics.gridSpacing
        GeometryReader { geo in
            let col = (geo.size.width - g * 3) / 4
            let bottomH: CGFloat = 92
            let rowH = (geo.size.height - bottomH - g * 2) / 2
            VStack(spacing: g) {
                HStack(spacing: g) {
                    FreeSpaceCard(model: model).frame(width: col * 2 + g)
                    CategoryCard(model: model, category: .creative)
                    CategoryCard(model: model, category: .dev)
                }
                .frame(height: rowH)
                HStack(spacing: g) {
                    CategoryCard(model: model, category: .ai)
                    CategoryCard(model: model, category: .system)
                    CategoryCard(model: model, category: .personal)
                    LastScanCard(model: model)
                }
                .frame(height: rowH)
                ScanBar(model: model)
                    .frame(height: bottomH)
            }
        }
    }
}

struct FreeSpaceCard: View {
    @Bindable var model: AppModel

    var body: some View {
        let disk = model.disk
        let found = model.lastResult?.totalBytes
        GlassCard("Macintosh HD", subtitle: "Свободное место", systemImage: "internaldrive.fill",
                  palette: .system, focus: .bottomLeading, glow: 0.9, animated: model.animated) {
            HStack(alignment: .center, spacing: 28) {
                DiskRing(used: Double(disk.used) / 1e9, total: Double(disk.total) / 1e9, palette: .system)
                    .frame(maxWidth: 210, maxHeight: 210)
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(found == nil ? "Можно освободить" : "Найдено при скане")
                            .font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
                        if let found {
                            let d = ByteDisplay(found)
                            DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .hero)
                        } else {
                            DotMatrixText("--", style: .hero.dimmed)
                        }
                    }
                    TickScale(value: disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0,
                              color: Palette.system.accent, leadingLabel: "0", trailingLabel: "\(Int(Double(disk.total) / 1e9))")
                    Text("Занято \(shortBytes(disk.used)) из \(shortBytes(disk.total))")
                        .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

struct CategoryCard: View {
    @Bindable var model: AppModel
    let category: RuleCategory

    var body: some View {
        let bytes = model.bytes(category: category)
        let results = model.lastResult?.results.filter { $0.rule.category == category } ?? []
        let blocked = results.filter { $0.status == .blockedByRunningApp }
        let maxBytes = max(1, model.lastResult?.totalBytes ?? 1)
        GlassCard(category.shortTitle, subtitle: category.subtitle, systemImage: category.systemImage,
                  palette: category.palette, glow: bytes == nil || bytes == 0 ? 0.45 : 1, animated: model.animated) {
            VStack(alignment: .leading, spacing: 12) {
                if let bytes, bytes > 0 {
                    let d = ByteDisplay(bytes)
                    DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .large)
                } else {
                    DotMatrixText(bytes == nil ? "--" : "0", style: .large.dimmed)
                }
                TickScale(value: Double(bytes ?? 0) / Double(maxBytes), tickCount: 31, color: .white, height: 16)
            }
        } footer: {
            HStack(spacing: 6) {
                if bytes == nil {
                    Text("не сканировано")
                } else if !blocked.isEmpty {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.Colors.review)
                    Text("Закрой \(appNames(for: blocked.flatMap(\.blockedBy)).joined(separator: ", "))").lineLimit(1)
                } else {
                    let tiers = Set(results.filter { !$0.items.isEmpty }.map(\.rule.tier)).sorted()
                    ForEach(tiers, id: \.self) { TierBadge($0.badge, compact: true) }
                    Text("\(results.filter { !$0.items.isEmpty }.count) из \(plural(results.count, "правила", "правил", "правил"))")
                }
            }
        }
    }
}

struct LastScanCard: View {
    @Bindable var model: AppModel

    var body: some View {
        GlassCard("Последний скан", subtitle: model.lastResult == nil ? "Ещё не было" : "Сегодня",
                  systemImage: "clock.arrow.circlepath", animated: model.animated) {
            VStack(alignment: .leading, spacing: 12) {
                if let r = model.lastResult {
                    DotMatrixText(ClockView.format(r.date), style: .large)
                    Text("\(plural(r.results.filter { !$0.items.isEmpty }.count, "находка", "находки", "находок")) · \(shortBytes(r.bytes(tier: .green))) безопасно")
                        .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                } else {
                    DotMatrixText("--:--", style: .large.dimmed)
                    Text("\(plural(model.rules.count, "правило", "правила", "правил")) в каталоге")
                        .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
    }
}

/// Bottom bar: scan depth + the big Сканировать button.
struct ScanBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: 8) {
                PillPicker(ScanMode.allCases.map { ($0, $0.title) }, selection: $model.mode)
                HStack(spacing: 6) {
                    ForEach(Tier.allCases, id: \.self) { tier in
                        TierBadge(tier.badge, compact: !model.mode.tiers.contains(tier))
                            .opacity(model.mode.tiers.contains(tier) ? 1 : 0.35)
                    }
                    Text(model.mode.hint)
                        .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if model.lastResult != nil {
                PillButton("Результаты", systemImage: "list.bullet") {
                    withAnimation(Theme.Motion.spring) { model.stage = .results }
                }
            }
            PrimaryScanButton("Сканировать",
                              subtitle: "\(plural(model.rulesForMode.count, "правило", "правила", "правил")) · \(model.mode.title.lowercased())",
                              palette: .system, animated: model.animated) {
                model.startScan()
            }
            .frame(width: 360)
            .disabled(model.rules.isEmpty)
        }
        .padding(.horizontal, 4)
    }
}

extension DotMatrixStyle {
    /// Same style, faded: placeholders («--»).
    var dimmed: DotMatrixStyle {
        var s = self
        s.color = .white.opacity(0.35)
        s.glow = 0
        return s
    }
}
