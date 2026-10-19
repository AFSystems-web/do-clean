import SwiftUI
import DoCleanCore

/// Scan results grouped by tier and category, with checkboxes and file lists.
struct ResultsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: Theme.Metrics.gridSpacing) {
            ResultsHeader(model: model)
                .frame(height: 150)
            if let result = model.lastResult {
                let groups = result.grouped()
                if groups.isEmpty {
                    EmptyResults(model: model)
                } else {
                    SnapshotSafeScroll {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(groups, id: \.tier) { group in
                                TierSection(model: model, group: group)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}

private struct ResultsHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        let total = model.lastResult?.totalBytes ?? 0
        let selected = model.selectedBytes
        GlassCard(nil, palette: .system, focus: .trailing, glow: 0.8, animated: model.animated) {
            HStack(alignment: .center, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Выбрано к очистке").font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
                    let d = ByteDisplay(selected, gigabytes: 1)
                    DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .hero)
                        .animation(Theme.Motion.count, value: selected)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Найдено \(shortBytes(total)) · выбрано \(plural(model.selectedItemCount, "объект", "объекта", "объектов"))")
                        .font(Theme.Fonts.cardTitle).foregroundStyle(.white)
                    TickScale(value: total > 0 ? Double(selected) / Double(total) : 0, tickCount: 41,
                              color: Palette.system.accent, leadingLabel: "0", trailingLabel: shortBytes(total))
                        .animation(Theme.Motion.spring, value: selected)
                    HStack(spacing: 6) {
                        ForEach(Tier.allCases, id: \.self) { tier in
                            let b = model.selectedBytes(tier: tier)
                            if b > 0 {
                                TierBadge(tier.badge, compact: true)
                                Text(shortBytes(b)).font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: 420)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 10) {
                    PrimaryScanButton("Очистить", subtitle: model.isDryRun ? "Тестовый режим" : plural(model.selectedItemCount, "объект", "объекта", "объектов"),
                                      palette: model.selectedBytes(tier: .red) > 0 ? .adobe : .system, animated: model.animated) {
                        model.confirming = true
                    }
                    .frame(width: 320)
                    .disabled(selected == 0)
                    .opacity(selected == 0 ? 0.5 : 1)
                    HStack(spacing: 8) {
                        PillButton("Главная", systemImage: "chevron.left") { model.backToDashboard() }
                        PillButton("Сканировать снова", systemImage: "arrow.clockwise") { model.startScan() }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct EmptyResults: View {
    @Bindable var model: AppModel

    var body: some View {
        GlassCard("Чисто", subtitle: "В режиме «\(model.mode.title)» убирать нечего", palette: .system,
                  focus: .bottom, glow: 0.6, animated: model.animated) {
            VStack(spacing: 12) {
                DotMatrixText("0", style: .hero)
                Text("Попробуй режим «Всё» или загляни позже").font(Theme.Fonts.cardSubtitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Sections

private struct TierSection: View {
    @Bindable var model: AppModel
    let group: TierGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TierBadge(group.tier.badge)
                Text(tierTitle).font(Theme.Fonts.title(20)).foregroundStyle(.white)
                Text(tierHint).font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                let d = ByteDisplay(group.bytes)
                DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .medium)
            }
            .padding(.horizontal, 6)
            ForEach(group.categories, id: \.category) { cat in
                VStack(alignment: .leading, spacing: 6) {
                    Text(cat.category.title.uppercased())
                        .font(.system(size: 11, weight: .semibold)).kerning(0.8)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .padding(.horizontal, 8).padding(.top, 4)
                    ForEach(cat.results) { r in
                        RuleRow(model: model, result: r)
                    }
                }
            }
        }
    }

    private var tierTitle: String {
        switch group.tier {
        case .green: "Безопасно"
        case .yellow: "Проверь"
        case .red: "Личное"
        }
    }

    private var tierHint: String {
        switch group.tier {
        case .green: "пересоздастся само, отмечено заранее"
        case .yellow: "можно скачать или собрать заново — отметь сам"
        case .red: "только по одному файлу, уходит в Корзину"
        }
    }
}

// MARK: - Rule row

struct RuleRow: View {
    @Bindable var model: AppModel
    let result: RuleResult
    @State private var hovering = false

    private var isExpanded: Bool { model.expanded.contains(result.id) }

    var body: some View {
        let palette = result.rule.paletteKey
        let blocked = result.status == .blockedByRunningApp
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                CheckBox(state: checkState, enabled: model.canToggleRule(result), tint: palette.primary) {
                    withAnimation(Theme.Motion.snappy) { model.toggleRule(result) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(result.rule.title.ru).font(Theme.Fonts.title(15)).foregroundStyle(.white)
                        if !result.rule.subtitle.ru.isEmpty {
                            Text(result.rule.subtitle.ru).font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                    Text(result.rule.whySafe.ru)
                        .font(.system(size: 12)).foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if blocked {
                        BlockerHint(result: result)
                    } else if result.rule.tier == .red {
                        Label("Отмечай файлы по одному в списке", systemImage: "hand.point.up.left.fill")
                            .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.personal.mix(.white, 0.3))
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    let d = ByteDisplay(result.bytes)
                    DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .medium)
                    let sel = model.selectedBytes(result)
                    Text(sel > 0 && sel < result.bytes ? "выбрано \(shortBytes(sel))" : plural(result.items.count, "объект", "объекта", "объектов"))
                        .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textTertiary)
                }
                Button {
                    withAnimation(Theme.Motion.spring) {
                        if isExpanded { model.expanded.remove(result.id) } else { model.expanded.insert(result.id) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Скрыть" : "Показать файлы")
                        Image(systemName: "chevron.down").rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .font(Theme.Fonts.footer)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(.white.opacity(0.07)))
                    .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            if isExpanded {
                ItemList(model: model, result: result)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            ZStack(alignment: .leading) {
                Theme.Colors.cardBase
                LinearGradient(colors: [palette.primary.opacity(hovering ? 0.22 : 0.14), .clear],
                               startPoint: .leading, endPoint: UnitPoint(x: 0.45, y: 0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(hovering ? 0.16 : 0.08), lineWidth: 1))
        .opacity(blocked ? 0.8 : 1)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.snappy, value: hovering)
    }

    private var checkState: CheckBox.State {
        switch model.check(result) {
        case .none: .off
        case .some: .mixed
        case .all: .on
        }
    }
}

/// «Закрой After Effects, чтобы освободить 46 ГБ».
struct BlockerHint: View {
    let result: RuleResult

    var body: some View {
        let names = appNames(for: result.blockedBy)
        Label("Закрой \(names.isEmpty ? "программу" : names.joined(separator: ", ")), чтобы освободить \(shortBytes(result.bytes))",
              systemImage: "lock.fill")
            .font(Theme.Fonts.footer)
            .foregroundStyle(Theme.Colors.review)
    }
}

// MARK: - Items

private struct ItemList: View {
    @Bindable var model: AppModel
    let result: RuleResult
    @State private var limit = 60

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            ForEach(result.items.prefix(limit)) { item in
                ItemRow(model: model, result: result, item: item)
            }
            if result.items.count > limit {
                Button("Показать ещё \(min(200, result.items.count - limit)) из \(result.items.count - limit)") {
                    limit += 200
                }
                .buttonStyle(.plain)
                .font(Theme.Fonts.footer).foregroundStyle(.white.opacity(0.7))
                .padding(.vertical, 10)
            }
        }
        .padding(.bottom, 8)
    }
}

private struct ItemRow: View {
    @Bindable var model: AppModel
    let result: RuleResult
    let item: ScanItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            CheckBox(state: model.isSelected(item, in: result) ? .on : .off, enabled: result.isCleanable,
                     tint: result.rule.paletteKey.primary, size: 16) {
                model.toggleItem(item, in: result)
            }
            Image(systemName: item.isCommand ? "terminal" : "doc")
                .font(.system(size: 12)).foregroundStyle(Theme.Colors.textTertiary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                Text(item.detail ?? item.path.map(Self.abbreviate) ?? "команда")
                    .font(.system(size: 11)).foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let used = item.lastUsed {
                Text(used, format: .relative(presentation: .named))
                    .font(.system(size: 11)).foregroundStyle(Theme.Colors.textTertiary)
            }
            Text(shortBytes(item.bytes))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 76, alignment: .trailing)
            if let url = item.url {
                IconButton(systemImage: "eye", help: "Быстрый просмотр") { QuickLook.shared.preview(url) }
                IconButton(systemImage: "folder", help: "Показать в Finder") { QuickLook.reveal(url) }
            } else {
                Color.clear.frame(width: 60, height: 1)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 6)
        .background(hovering ? Color.white.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
        .contextMenu {
            if let url = item.url {
                Button("Быстрый просмотр") { QuickLook.shared.preview(url) }
                Button("Показать в Finder") { QuickLook.reveal(url) }
            }
        }
    }

    static func abbreviate(_ path: String) -> String { abbreviatePath(path) }
}

// MARK: - Controls

struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hovering ? 0.16 : 0.07)))
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Round checkbox with mixed state, tinted by the rule palette.
struct CheckBox: View {
    enum State { case off, mixed, on }
    let state: State
    let enabled: Bool
    var tint: Color = Theme.Colors.safe
    var size: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white.opacity(enabled ? 0.35 : 0.12), lineWidth: 1.5)
                if state != .off {
                    Circle().fill(tint).shadow(color: tint.opacity(0.7), radius: 6)
                    Image(systemName: state == .on ? "checkmark" : "minus")
                        .font(.system(size: size * 0.5, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityValue(Text(state == .on ? "выбрано" : state == .mixed ? "частично" : "не выбрано"))
    }
}

// MARK: - Snapshot support

extension EnvironmentValues {
    /// True while rendering offscreen with ImageRenderer (no ScrollView there).
    @Entry var isSnapshot = false
}

/// A vertical ScrollView in the app; a top-aligned clipped stack in snapshots.
struct SnapshotSafeScroll<Content: View>: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @ViewBuilder let content: Content

    var body: some View {
        if isSnapshot {
            Color.clear
                .overlay(alignment: .top) { content }
                .clipped()
        } else {
            ScrollView { content }.scrollIndicators(.never)
        }
    }
}

/// `/Users/me/Downloads/x` → `~/Downloads/x`.
func abbreviatePath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
