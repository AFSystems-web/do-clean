import SwiftUI
import AppKit
import DoCleanCore

/// «Порядок»: sources → preset → customize → preview → apply → done (+ undo, history).
struct StructurizeView: View {
    @Bindable var model: AppModel
    @Bindable var s: StructurizeModel

    var body: some View {
        ZStack {
            switch s.stage {
            case .choose: ChooseStage(model: model, s: s).transition(.opacity)
            case .customize: CustomizeStage(model: model, s: s).transition(.opacity)
            case .preview: PreviewStage(model: model, s: s).transition(.opacity)
            case .applying: ApplyingStage(model: model, s: s).transition(.opacity)
            case .done: DoneStage(model: model, s: s).transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.bottom, Theme.Metrics.screenPadding)
        .sheet(isPresented: $s.confirming) { StructurizeConfirmSheet(model: model, s: s) }
    }
}

// MARK: - Choose

private struct ChooseStage: View {
    @Bindable var model: AppModel
    @Bindable var s: StructurizeModel

    var body: some View {
        let g = Theme.Metrics.gridSpacing
        VStack(spacing: g) {
            SourceBar(model: model, s: s).frame(height: 118)
            SnapshotSafeHScroll {
                HStack(spacing: g) {
                    ForEach(s.presets) { p in
                        PresetCard(model: model, s: s, preset: p).frame(width: 268)
                    }
                }
            }
            .frame(height: 300)
            HStack(spacing: g) {
                LayoutHistoryCard(model: model, s: s)
                ChooseActions(model: model, s: s).frame(width: 400)
            }
        }
    }
}

private struct SourceBar: View {
    @Bindable var model: AppModel
    @Bindable var s: StructurizeModel

    var body: some View {
        GlassCard("Порядок", subtitle: "Раскладываю файлы по папкам. Ничего не удаляю — всё можно отменить.",
                  systemImage: "square.stack.3d.up.fill", palette: .downloads, focus: .trailing, glow: 0.6, animated: model.animated) {
            HStack(spacing: 8) {
                Text("Где:").font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                ForEach([StructureSource.desktop, .downloads, .documents] + s.sources.filter { if case .custom = $0 { true } else { false } }) { src in
                    ToggleChip(title: src.title, systemImage: icon(src), on: s.sources.contains(src)) {
                        withAnimation(Theme.Motion.snappy) { s.toggleSource(src) }
                    }
                }
                ToggleChip(title: "Выбрать папку…", systemImage: "folder.badge.plus", on: false) { pickFolder() }
                Spacer()
                ToggleChip(title: "с подпапками", systemImage: "list.bullet.indent", on: s.recursive) {
                    s.recursive.toggle()
                }
                if model.isDryRun { DryRunBadge() }
            }
        }
    }

    private func icon(_ s: StructureSource) -> String {
        switch s {
        case .desktop: "menubar.dock.rectangle"
        case .downloads: "arrow.down.circle"
        case .documents: "doc.on.doc"
        case .custom: "folder"
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Навести порядок"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        s.addCustomSource(url)
    }
}

/// Chip that toggles (multi-select).
struct ToggleChip: View {
    let title: String
    var systemImage: String? = nil
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 11).frame(height: 28)
            .foregroundStyle(on ? Color.black : .white.opacity(0.85))
            .background(Capsule().fill(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.3))))
            .overlay(Capsule().strokeBorder(.white.opacity(on ? 0 : 0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

private struct PresetCard: View {
    @Bindable var model: AppModel
    @Bindable var s: StructurizeModel
    let preset: StructurePreset

    var body: some View {
        let selected = s.selectedPresetID == preset.id
        GlassCard(preset.title.ru, subtitle: preset.subtitle.ru.isEmpty ? "Мой пресет" : preset.subtitle.ru,
                  systemImage: selected ? "checkmark" : preset.systemImage, palette: preset.palette,
                  focus: .bottomTrailing, glow: selected ? 1 : 0.4, animated: model.animated,
                  action: { withAnimation(Theme.Motion.spring) { s.select(preset) } }) {
            TinyTree(lines: preset.treePreview(), accent: preset.palette.accent)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.32)))
        } footer: {
            HStack(spacing: 6) {
                Text(preset.strategy == .creative ? "проекты целиком" :
                        plural(preset.rules.filter(\.enabled).count, "правило", "правила", "правил"))
                Spacer()
                if !preset.isBuiltIn {
                    Text("мой").font(Theme.Fonts.badge).padding(.horizontal, 7).frame(height: 18)
                        .background(Capsule().fill(.white.opacity(0.14))).foregroundStyle(.white)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
            .strokeBorder(.white.opacity(selected ? 0.55 : 0), lineWidth: 1.5))
    }
}

/// Tiny folder tree: indented folder names.
struct TinyTree: View {
    let lines: [(depth: Int, name: String)]
    var accent: Color = .white
    var fontSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    if line.depth > 0 {
                        Text(String(repeating: "  ", count: line.depth - 1) + "└")
                            .font(.system(size: fontSize, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
                    }
                    Image(systemName: "folder.fill").font(.system(size: fontSize - 1)).foregroundStyle(accent)
                    Text(line.name).font(.system(size: fontSize, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                }
            }
        }
    }
}

private struct ChooseActions: View {
    @Bindable var model: AppModel
    @Bindable var s: StructurizeModel

    var body: some View {
        let preset = s.draft
        GlassCard("Выбрано: \(preset.title.ru)", subtitle: s.sources.map(\.title).joined(separator: ", "),
                  systemImage: preset.systemImage, palette: preset.palette, focus: .bottom, glow: 0.55, animated: model.animated) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Сначала покажу «было → станет». Перемещу только после твоего «Разложить».")
                    .font(Theme.Fonts.cardSubtitle).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                PillButton("Настроить", systemImage: "slider.horizontal.3") {
                    withAnimation(Theme.Motion.spring) { s.stage = .customize }
                }
                PrimaryScanButton("Показать, что будет", subtitle: "Только смотрю, ничего не двигаю",
                                  palette: preset.palette, animated: model.animated) { s.makePlan() }
            }
        }
    }
}

// MARK: - Customize

private struct CustomizeStage: View {
    @Bindable var model: AppModel
    @Bindable var s: StructurizeModel
    @State private var presetName = ""

    var body: some View {
        let g = Theme.Metrics.gridSpacing
        HStack(alignment: .top, spacing: g) {
            GlassCard("Правила «\(s.draft.title.ru)»", subtitle: "Маска → папка. Переименуй папки прямо здесь.",
                      systemImage: "slider.horizontal.3", palette: s.draft.palette, focus: .bottomTrailing, glow: 0.35,
                      animated: model.animated) {
                SnapshotSafeScroll {
                    VStack(spacing: 6) {
                        if s.draft.strategy == .creative, let layout = s.draft.projectLayout {
                            LayoutEditor(layout: layout) { s.updateLayout($0) }
                        }
                        ForEach(s.draft.rules) { rule in
                            RuleRowEditor(rule: rule, accent: s.draft.palette.primary,
                                          onChange: { s.updateRule($0) }, onDelete: { s.removeRule(rule.id) })
                        }
                        HStack {
                            PillButton("Добавить правило", systemImage: "plus") { withAnimation(Theme.Motion.snappy) { s.addRule() } }
                            Spacer()
                        }
                        .padding(.top, 6)
                    }
                    .padding(.top, 10)
                }
            }
            VStack(spacing: g) {
                GlassCard("Получится так", subtitle: "Новые папки", systemImage: "folder.fill", palette: s.draft.palette,
                          focus: .bottom, glow: 0.5, animated: model.animated) {
                    TinyTree(lines: s.draft.treePreview(limit: 9), accent: s.draft.palette.accent, fontSize: 13)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, 10)
                }
                GlassCard("Сохранить как пресет", subtitle: "Появится рядом с готовыми", systemImage: "star.fill",
                          animated: model.animated) {
                    VStack(alignment: .leading, spacing: 10) {
                        InlineField(text: $presetName, placeholder: s.draft.title.ru + " (моя)", width: nil)
                        PillButton("Сохранить", systemImage: "square.and.arrow.down", selected: true) {
                            withAnimation(Theme.Motion.spring) { _ = s.saveDraftAsPreset(named: presetName) }
                            presetName = ""
                        }
                    }
                    .padding(.top, 8)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    PillButton("Назад", systemImage: "chevron.left") { withAnimation(Theme.Motion.spring) { s.stage = .choose } }
                    Spacer()
                }
                PrimaryScanButton("Показать, что будет", subtitle: "Только смотрю", palette: s.draft.palette,
                                  animated: model.animated) { s.makePlan() }
            }
            .frame(width: 400)
        }
    }
}

private struct RuleRowEditor: View {
    let rule: StructureRule
    let accent: Color
    let onChange: (StructureRule) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(state: rule.enabled ? .on : .off, enabled: true, tint: accent, size: 18) {
                var r = rule; r.enabled.toggle(); onChange(r)
            }
            InlineField(text: Binding(get: { rule.name }, set: { v in var r = rule; r.name = v; onChange(r) }),
                        placeholder: "Название", width: 190)
            InlineField(text: Binding(get: { StructurizeModel.maskText(rule) }, set: { v in
                var r = rule
                if v.trimmingCharacters(in: .whitespaces) == "все файлы" { r.matchesAll = true; r.extensions = []; r.globs = [] }
                else { let m = StructurizeModel.parseMask(v); r.extensions = m.extensions; r.globs = m.globs; r.matchesAll = false }
                onChange(r)
            }), placeholder: "mp4 mov *.braw", width: nil, monospaced: true)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(accent)
            InlineField(text: Binding(get: { rule.target }, set: { v in var r = rule; r.target = v; onChange(r) }),
                        placeholder: "Папка", width: 170)
            IconButton(systemImage: "xmark", help: "Убрать правило", action: onDelete)
        }
        .opacity(rule.enabled ? 1 : 0.5)
        .padding(.horizontal, 10).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.28)))
    }
}

private struct LayoutEditor: View {
    let layout: ProjectLayout
    let onChange: (ProjectLayout) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Папка проекта угадывается по общему началу имён и по папкам с проектами.")
                .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
            field("Корень", \.root)
            HStack(spacing: 8) {
                field("Исходники", \.sources)
                field("Рендеры", \.renders)
                field("Монтаж", \.edit)
            }
            HStack(spacing: 8) {
                field("Звук", \.audio)
                field("Экспорт", \.exports)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.28)))
    }

    private func field(_ label: String, _ kp: WritableKeyPath<ProjectLayout, String>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textTertiary)
            InlineField(text: Binding(get: { layout[keyPath: kp] }, set: { v in var l = layout; l[keyPath: kp] = v; onChange(l) }),
                        placeholder: label, width: 130)
        }
    }
}

/// Text field styled for the dark glass; plain text in snapshots (ImageRenderer can't draw NSTextField).
struct InlineField: View {
    @Binding var text: String
    let placeholder: String
    let width: CGFloat?
    var monospaced = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Group {
            if isSnapshot {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(.white.opacity(text.isEmpty ? 0.35 : 0.92))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
            }
        }
        .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13, weight: .medium))
        .padding(.horizontal, 9).frame(height: 28)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }
}

/// Horizontal ScrollView in the app, plain clipped row in snapshots.
struct SnapshotSafeHScroll<Content: View>: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @ViewBuilder let content: Content

    var body: some View {
        if isSnapshot {
            Color.clear.overlay(alignment: .leading) { content }.clipped()
        } else {
            ScrollView(.horizontal) { content }.scrollIndicators(.never)
        }
    }
}
