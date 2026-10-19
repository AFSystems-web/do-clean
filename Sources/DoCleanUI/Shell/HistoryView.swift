import SwiftUI
import Charts
import DoCleanCore

/// «История»: total freed, chart by day/week, breakdown by category.
struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var weekly = false

    var body: some View {
        let stats = model.historyStats()
        let g = Theme.Metrics.gridSpacing
        VStack(spacing: g) {
            HStack(spacing: g) {
                GlassCard("Освобождено всего", subtitle: stats.cleanupCount == 0 ? "Ещё ни одной настоящей чистки" :
                            "За \(plural(stats.cleanupCount, "очистку", "очистки", "очисток"))",
                          systemImage: "sparkles", palette: .system, focus: .bottomLeading, animated: model.animated) {
                    let d = ByteDisplay(stats.totalFreed)
                    DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: DotMatrixStyle(dotSize: 8, spacing: 2.8))
                }
                GlassCard("За 30 дней", subtitle: "Сколько вернулось места", systemImage: "calendar",
                          palette: .xcode, animated: model.animated) {
                    let d = ByteDisplay(stats.freed(since: Date().addingTimeInterval(-30 * 86_400)))
                    DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .large)
                }
                GlassCard("Последняя чистка", subtitle: stats.lastCleanup.map { $0.formatted(.relative(presentation: .named)) } ?? "Не было",
                          systemImage: "clock.arrow.circlepath", palette: .ai, animated: model.animated) {
                    DotMatrixText(stats.lastCleanup.map { ClockView.format($0) } ?? "--:--",
                                  style: stats.lastCleanup == nil ? .large.dimmed : .large)
                }
            }
            .frame(height: 200)

            HStack(spacing: g) {
                GlassCard(weekly ? "По неделям" : "По дням", subtitle: weekly ? "Последние 12 недель" : "Последние 30 дней",
                          systemImage: "chart.bar.fill", animated: model.animated) {
                    VStack(alignment: .trailing, spacing: 10) {
                        ChipRow(options: [(false, "дни"), (true, "недели")], selection: $weekly, label: nil)
                        FreedChart(buckets: weekly ? stats.perWeek(last: 12) : stats.perDay(last: 30), weekly: weekly)
                    }
                }
                CategoryBreakdown(stats: stats, animated: model.animated)
                    .frame(width: 380)
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.bottom, Theme.Metrics.screenPadding)
    }
}

private struct FreedChart: View {
    let buckets: [HistoryStats.Bucket]
    let weekly: Bool

    var body: some View {
        let accent = Palette.system.accent
        Chart(buckets) { b in
            BarMark(x: .value("Дата", b.start, unit: weekly ? .weekOfYear : .day),
                    y: .value("ГБ", Double(b.bytes) / 1e9))
                .foregroundStyle(LinearGradient(colors: [Palette.system.secondary, Palette.system.primary, accent],
                                                startPoint: .bottom, endPoint: .top))
                .cornerRadius(4)
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4])).foregroundStyle(.white.opacity(0.12))
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) ГБ") } }
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: weekly ? .weekOfYear : .day, count: weekly ? 2 : 5)) { _ in
                AxisTick().foregroundStyle(.white.opacity(0.3))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .overlay {
            if buckets.allSatisfy({ $0.bytes == 0 }) {
                Text("Здесь появится график после первой настоящей очистки")
                    .font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }
}

private struct CategoryBreakdown: View {
    let stats: HistoryStats
    let animated: Bool

    var body: some View {
        let by = stats.byCategory()
        let total = max(1, by.values.reduce(0, +))
        GlassCard("По категориям", subtitle: "Откуда пришло место", systemImage: "square.grid.2x2.fill",
                  palette: .personal, focus: .bottomTrailing, glow: 0.5, animated: animated) {
            VStack(spacing: 14) {
                ForEach(RuleCategory.allCases, id: \.self) { cat in
                    let b = by[cat] ?? 0
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle().fill(cat.palette.primary).frame(width: 8, height: 8)
                                .shadow(color: cat.palette.primary, radius: 4)
                            Text(cat.shortTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            Spacer()
                            Text(shortBytes(b)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(b > 0 ? 0.85 : 0.35))
                        }
                        TickScale(value: Double(b) / Double(total), tickCount: 41, accentEvery: 10, color: cat.palette.accent, height: 12)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
