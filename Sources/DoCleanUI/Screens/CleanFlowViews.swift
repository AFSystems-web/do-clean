import SwiftUI
import DoCleanCore

// MARK: - Confirm

/// Confirmation before cleaning. Red files are listed one by one.
struct ConfirmCleanSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        let reqs = model.requests
        let red = reqs.filter { $0.rule.tier == .red }
        let redItems = red.flatMap { r in r.items.map { (r.rule, $0) } }
        let total = model.requestedBytes
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Очистить?").font(Theme.Fonts.title(24)).foregroundStyle(.white)
                    Text(plural(model.selectedItemCount, "объект", "объекта", "объектов") + " · " +
                         (model.cleanSourceTool?.title ?? plural(reqs.count, "категория", "категории", "категорий")))
                        .font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                let d = ByteDisplay(total)
                DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .large)
            }

            if model.isDryRun {
                Notice(color: Theme.Colors.review, systemImage: "testtube.2",
                       text: "Тестовый режим: файлы не удалятся. Покажем, сколько освободилось бы.")
            }

            VStack(spacing: 8) {
                ForEach(Tier.allCases, id: \.self) { tier in
                    let rs = reqs.filter { $0.rule.tier == tier }
                    if !rs.isEmpty {
                        TierSummaryRow(tier: tier, requests: rs)
                    }
                }
            }

            if !redItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Эти личные файлы уйдут в Корзину", systemImage: "trash")
                        .font(Theme.Fonts.cardTitle).foregroundStyle(Theme.Colors.personal.mix(.white, 0.3))
                    SnapshotSafeScroll {
                        VStack(spacing: 0) {
                            ForEach(redItems, id: \.1.id) { rule, item in
                                HStack(spacing: 10) {
                                    Image(systemName: "doc").foregroundStyle(Theme.Colors.textTertiary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                                        Text(item.path ?? rule.title.ru).font(.system(size: 11))
                                            .foregroundStyle(Theme.Colors.textTertiary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(shortBytes(item.bytes)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                .padding(.vertical, 6).padding(.horizontal, 12)
                            }
                        }
                    }
                    .frame(height: min(220, CGFloat(redItems.count) * 44 + 4))
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.3)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Colors.personal.opacity(0.3)))
                }
            }

            HStack(spacing: 10) {
                PillButton("Отмена") { model.confirming = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                PrimaryScanButton(model.isDryRun ? "Проверить очистку" : "Очистить \(shortBytes(total))",
                                  subtitle: model.isDryRun ? "Тестовый режим" : (redItems.isEmpty ? nil : "Личное — в Корзину"),
                                  palette: redItems.isEmpty ? .system : .adobe, animated: model.animated) {
                    model.clean()
                }
                .frame(width: 340)
            }
        }
        .padding(28)
        .frame(width: 640)
        .background(Color(hex: 0x16161A))
        .preferredColorScheme(.dark)
    }
}

private struct TierSummaryRow: View {
    let tier: Tier
    let requests: [CleanRequest]

    var body: some View {
        let bytes = requests.reduce(Int64(0)) { $0 + $1.items.reduce(0) { $0 + $1.bytes } }
        let count = requests.reduce(0) { $0 + $1.items.count }
        HStack(spacing: 10) {
            TierBadge(tier.badge)
            Text(requests.map(\.rule.title.ru).joined(separator: ", "))
                .font(.system(size: 12)).foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(method).font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textTertiary)
            Text("\(shortBytes(bytes)) · \(count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
    }

    private var method: String {
        let methods = Set(requests.map(\.rule.deletion))
        if methods == [.trash] { return "в Корзину" }
        if methods == [.delete] { return "сразу" }
        if methods == [.command] { return "командой" }
        return "по правилам"
    }
}

struct Notice: View {
    let color: Color
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color.mix(.white, 0.2))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - Cleaning

struct CleaningView: View {
    @Bindable var model: AppModel

    var body: some View {
        let progress = model.cleanTotalItems > 0 ? Double(model.cleanDoneItems) / Double(model.cleanTotalItems) : 0
        let reqs = model.requests
        HStack(spacing: Theme.Metrics.gridSpacing) {
            GlassCard(model.isDryRun ? "Проверяю очистку" : "Очищаю", subtitle: model.isDryRun ? "Тестовый режим · ничего не удаляется" : "Каждый файл проверяется перед удалением",
                      systemImage: "sparkles", palette: .system, focus: .bottom, glow: 0.4 + 0.6 * progress, animated: model.animated) {
                VStack(alignment: .leading, spacing: 22) {
                    Spacer()
                    HStack(alignment: .center, spacing: 32) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.isDryRun ? "Освободилось бы" : "Освобождено").font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
                            let d = ByteDisplay(model.cleanFreed, gigabytes: 1)
                            DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: DotMatrixStyle(dotSize: 8, spacing: 2.8))
                                .animation(Theme.Motion.spring, value: model.cleanFreed)
                        }
                        Spacer(minLength: 0)
                        let before = model.diskBefore ?? model.disk
                        DiskRing(used: Double(before.used - model.cleanFreed) / 1e9, total: Double(before.total) / 1e9,
                                 palette: .system, caption: model.isDryRun ? "было бы свободно" : "свободно")
                            .frame(width: 230, height: 230)
                    }
                    Spacer()
                    RunningScale(progress: progress, animated: model.animated)
                    HStack {
                        Text(model.cleanCurrent.map { "Сейчас: \($0)" } ?? "Готовлю…")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        DotMatrixText("\(model.cleanDoneItems)/\(model.cleanTotalItems)", style: .small)
                    }
                    .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            GlassCard("По категориям", subtitle: plural(reqs.count, "правило", "правила", "правил"),
                      systemImage: "list.bullet", animated: model.animated) {
                SnapshotSafeScroll {
                    VStack(spacing: 6) {
                        ForEach(Array(progressRows(reqs).enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 10) {
                                Image(systemName: row.done ? "checkmark.circle.fill" : (row.active ? "circle.dotted" : "circle"))
                                    .foregroundStyle(row.done ? Theme.Colors.safe : .white.opacity(row.active ? 0.9 : 0.3))
                                Text(row.title).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(row.done || row.active ? 0.95 : 0.5)).lineLimit(1)
                                Spacer()
                                Text(shortBytes(row.bytes)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(row.rule.paletteKey.primary.opacity(row.active ? 0.18 : 0.06)))
                        }
                    }
                }
            }
            .frame(width: 420)
        }
    }

    private struct Row { let rule: Rule; let title: String; let bytes: Int64; let done: Bool; let active: Bool }

    /// Requests are cleaned in order, so cumulative counts tell which ones are done.
    private func progressRows(_ reqs: [CleanRequest]) -> [Row] {
        var start = 0
        return reqs.map { r in
            let end = start + r.items.count
            defer { start = end }
            let done = model.cleanDoneItems >= end
            let active = !done && model.cleanDoneItems >= start
            return Row(rule: r.rule, title: r.rule.title.ru, bytes: r.items.reduce(0) { $0 + $1.bytes }, done: done, active: active)
        }
    }
}

// MARK: - Finished

struct FinishedView: View {
    @Bindable var model: AppModel
    @State private var shown: Double = 0
    @State private var shownFree: Double = 0

    var body: some View {
        let report = model.report
        let freed = report?.freedBytes ?? model.cleanFreed
        let before = model.diskBefore ?? model.disk
        let after = model.diskAfter ?? model.disk
        let dry = report?.dryRun ?? model.isDryRun
        let target = Double(freed) / 1e9
        let targetFree = Double(after.free) / 1e9
        GlassCard(nil, palette: .system, focus: .bottom, glow: 0.6, animated: model.animated) {
            ZStack {
                CalmCelebration(animated: model.animated)
                VStack(spacing: 26) {
                    VStack(spacing: 10) {
                        Text(dry ? "Освободилось бы" : "Освобождено")
                            .font(Theme.Fonts.title(22)).foregroundStyle(.white)
                        DotMatrixNumber(model.animated ? shown : target, decimals: target < 10 ? 1 : 0, unit: "ГБ",
                                        style: DotMatrixStyle(dotSize: 9, spacing: 3.2))
                    }
                    HStack(spacing: 28) {
                        FreeColumn(title: "Было свободно", bytes: Double(before.free) / 1e9, dim: true)
                        Image(systemName: "arrow.right").font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Palette.system.accent)
                        FreeColumn(title: dry ? "Стало бы" : "Стало свободно",
                                   bytes: model.animated ? shownFree : targetFree, dim: false)
                    }
                    .padding(.horizontal, 28).padding(.vertical, 18)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.45)))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))

                    summary(report: report, dry: dry)

                    HStack(spacing: 10) {
                        PillButton(model.cleanSourceTool == nil ? "На главную" : "К инструментам",
                                   systemImage: model.cleanSourceTool == nil ? "house" : "wrench.and.screwdriver",
                                   selected: true) { model.backToDashboard() }
                        if dry && model.cleanSourceTool == nil {
                            PillButton("К результатам", systemImage: "list.bullet") {
                                withAnimation(Theme.Motion.spring) { model.stage = .results }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            guard model.animated else { return }
            shown = 0
            shownFree = Double(before.free) / 1e9
            withAnimation(Theme.Motion.count.delay(0.2)) {
                shown = target
                shownFree = targetFree
            }
        }
    }

    @ViewBuilder private func summary(report: CleanReport?, dry: Bool) -> some View {
        let skipped = report?.skipped.count ?? 0
        let failed = report?.failed.count ?? 0
        let ok = (report?.entries.count ?? 0) - skipped - failed
        HStack(spacing: 10) {
            if dry { DryRunBadge() }
            TierBadge(.safe, compact: true)
            Text(dry ? "прошли проверку: \(ok)" : "удалено: \(ok)")
            if skipped > 0 {
                TierBadge(.review, compact: true)
                Text("пропущено: \(skipped)")
            }
            if failed > 0 {
                TierBadge(.personal, compact: true)
                Text("не получилось: \(failed)")
            }
        }
        .font(Theme.Fonts.footer)
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 14).frame(height: 38)
        .background(Capsule().fill(.black.opacity(0.4)))
        .help(report.map { r in
            (r.skipped + r.failed).prefix(8).map { e -> String in
                switch e.outcome {
                case .skipped(let why), .failed(let why): "\(e.item.name): \(why)"
                default: e.item.name
                }
            }.joined(separator: "\n")
        } ?? "")
    }
}

private struct FreeColumn: View {
    let title: String
    let bytes: Double
    let dim: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
            DotMatrixNumber(bytes, decimals: 1, unit: "ГБ",
                            style: dim ? DotMatrixStyle(dotSize: 4.6, spacing: 1.8, color: .white.opacity(0.6), glow: 0.2) : DotMatrixStyle(dotSize: 4.6, spacing: 1.8, color: Palette.system.accent))
        }
    }
}

/// Calm celebration: soft rings breathing out and a few dots drifting up. Static under Reduce Motion.
struct CalmCelebration: View {
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = !animated || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            let t = still ? 2.4 : context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height * 0.42)
                let maxR = max(size.width, size.height) * 0.55
                // Rings.
                for i in 0..<3 {
                    let p = (t / 6 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    let r = 80 + p * maxR
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(Palette.system.accent.opacity((1 - p) * 0.22)), lineWidth: 1.2)
                }
                // Drifting dots, deterministic per index.
                for i in 0..<46 {
                    let seed = Double(i) * 12.9898
                    let fx = (sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)
                    let speed = 0.03 + abs(sin(seed * 1.7)) * 0.04
                    let p = (t * speed + abs(fx)).truncatingRemainder(dividingBy: 1)
                    let x = size.width * (0.5 + fx * 0.48) + sin(t * 0.6 + seed) * 8
                    let y = size.height * (1.05 - p * 1.1)
                    let alpha = sin(p * .pi) * 0.75
                    let s = 2.0 + abs(sin(seed * 3.1)) * 2.5
                    let color = i % 3 == 0 ? Palette.system.secondary : Palette.system.accent
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)), with: .color(color.opacity(alpha)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
