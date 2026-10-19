import SwiftUI
import AppKit
import DoCleanCore

/// «Настройки»: exclusions, reminder, large-file threshold, green-tier method, language, launch at login.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var loginError: String?
    @State private var loginOn = LaunchAtLogin.isEnabled

    private var s: AppSettings { model.settings.settings }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.gridSpacing) {
            ExclusionsCard(model: model)
            VStack(spacing: Theme.Metrics.gridSpacing) {
                card("Напоминание", "Раз в N дней после последней чистки, в 10:00", "bell.fill", .ai) {
                    ChipRow(options: [(0, "выкл"), (3, "3 дня"), (7, "неделя"), (14, "2 недели"), (30, "месяц")],
                            selection: Binding(get: { s.reminderDays }, set: { v in
                                model.settings.settings.reminderDays = v
                                rescheduleReminder()
                            }), label: nil)
                }
                card("Большие файлы", "Порог для инструмента «Большие файлы»", "externaldrive.fill", .adobe) {
                    ChipRow(options: [(100, "100 МБ"), (250, "250 МБ"), (500, "500 МБ"), (1000, "1 ГБ"), (5000, "5 ГБ")],
                            selection: Binding(get: { Int(s.largeFileThreshold / 1_000_000) }, set: { v in
                                model.settings.settings.largeFileThreshold = Int64(v) * 1_000_000
                                model.tools.largeMinMB = v
                            }), label: nil)
                }
                card("Зелёный уровень", "Кэши можно удалять сразу или класть в Корзину", "leaf.fill", .system) {
                    ChipRow(options: [(DeletionMethod.delete, "удалять сразу"), (.trash, "в Корзину")],
                            selection: Binding(get: { s.greenMethod }, set: { model.settings.settings.greenMethod = $0 }), label: nil)
                }
                HStack(spacing: Theme.Metrics.gridSpacing) {
                    card("Язык", "Интерфейс", "globe", .xcode) {
                        ChipRow(options: [(Language.ru, "Русский"), (.en, "English")],
                                selection: Binding(get: { s.language }, set: { model.settings.settings.language = $0 }), label: nil)
                    }
                    card("Автозапуск", loginError ?? "При входе в систему", "power", .trash) {
                        ChipRow(options: [(false, "выкл"), (true, "вкл")],
                                selection: Binding(get: { loginOn }, set: { v in
                                    loginError = LaunchAtLogin.set(v)
                                    loginOn = LaunchAtLogin.isEnabled
                                }), label: nil)
                    }
                }
            }
            .frame(width: 520)
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.bottom, Theme.Metrics.screenPadding)
    }

    private func rescheduleReminder() {
        Reminders.reschedule(settings: model.settings.settings,
                             history: History(fileURL: History.defaultURL(home: model.environment.home)), rules: model.rules)
    }

    private func card<C: View>(_ title: String, _ subtitle: String, _ icon: String, _ palette: Palette,
                               @ViewBuilder _ content: () -> C) -> some View {
        GlassCard(title, subtitle: subtitle, systemImage: icon, palette: palette, focus: .trailing, glow: 0.45,
                  animated: model.animated) {
            content().frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Folder and rule exclusions.
private struct ExclusionsCard: View {
    @Bindable var model: AppModel

    var body: some View {
        let s = model.settings.settings
        GlassCard("Исключения", subtitle: "Эти папки и правила do clean не трогает и не сканирует",
                  systemImage: "nosign", palette: .personal, focus: .bottomTrailing, glow: 0.4, animated: model.animated) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("ПАПКИ").font(.system(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(Theme.Colors.textTertiary)
                    Spacer()
                    PillButton("Добавить папку", systemImage: "plus") { addFolder() }
                }
                if s.excludedPaths.isEmpty {
                    Text("Пока нет. Например, папка с проектами, которые нельзя трогать.")
                        .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textTertiary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(s.excludedPaths, id: \.self) { path in
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(Palette.personal.primary)
                                Text(path).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                IconButton(systemImage: "xmark", help: "Убрать из исключений") { model.settings.include(path: path) }
                            }
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.25)))
                        }
                    }
                }
                Text("ПРАВИЛА").font(.system(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(Theme.Colors.textTertiary)
                    .padding(.top, 6)
                SnapshotSafeScroll {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(RuleCategory.allCases, id: \.self) { cat in
                            let rules = model.rules.filter { $0.category == cat }
                            if !rules.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cat.title).font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                                    ForEach(rules) { r in
                                        let off = s.excludedRuleIDs.contains(r.id)
                                        HStack(spacing: 10) {
                                            CheckBox(state: off ? .off : .on, enabled: true, tint: Theme.Colors.safe, size: 16) {
                                                model.settings.setRule(r.id, excluded: !off)
                                            }
                                            Text(r.title.ru).font(.system(size: 13)).foregroundStyle(.white.opacity(off ? 0.45 : 0.9))
                                            Spacer()
                                            TierBadge(r.tier.badge, compact: true)
                                        }
                                        .frame(height: 26)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Исключить"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.settings.exclude(path: abbreviatePath(url.path)) }
    }
}
