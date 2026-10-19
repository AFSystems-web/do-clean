import SwiftUI
import DoCleanCore

/// «Инструменты»: tool cards on the left, the selected tool on the right.
struct ToolsView: View {
    @Bindable var model: AppModel

    var body: some View {
        let tools = model.tools
        HStack(alignment: .top, spacing: Theme.Metrics.gridSpacing) {
            VStack(spacing: 10) {
                ForEach(ToolKind.allCases) { kind in
                    ToolCard(model: model, kind: kind, selected: tools.current == kind) {
                        withAnimation(Theme.Motion.spring) { tools.current = kind }
                        if !tools.hasOutput(kind) && !tools.isRunning(kind) { tools.run(kind) }
                    }
                }
            }
            .frame(width: 290)
            ToolPanel(model: model, kind: tools.current)
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.bottom, Theme.Metrics.screenPadding)
        .onAppear {
            for kind in model.toolsNeedRefresh { tools.run(kind) }
            model.toolsNeedRefresh = []
            if !tools.hasOutput(tools.current) && !tools.isRunning(tools.current) && model.animated {
                tools.run(tools.current)
            }
        }
    }
}

private struct ToolCard: View {
    @Bindable var model: AppModel
    let kind: ToolKind
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let tools = model.tools
        Button(action: action) {
            HStack(spacing: 12) {
                GlassIcon(systemImage: kind.systemImage, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title).font(Theme.Fonts.title(15)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                    Group {
                        if tools.isRunning(kind) {
                            Text("Ищу… \(tools.progress(kind)?.filesVisited ?? 0)")
                        } else if let n = tools.foundCount(kind) {
                            Text(n == 0 ? "ничего не нашлось" : plural(n, "находка", "находки", "находок"))
                        } else {
                            Text("не запускали")
                        }
                    }
                    .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer(minLength: 4)
                if let b = tools.foundBytes(kind), b > 0 {
                    let d = ByteDisplay(b)
                    DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .small)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 72)
            .background {
                ZStack {
                    Theme.Colors.cardBase
                    if selected {
                        MeshBlur(kind.palette, focus: .trailing, intensity: 0.75, animated: model.animated)
                    } else {
                        LinearGradient(colors: [kind.palette.primary.opacity(0.16), .clear], startPoint: .trailing, endPoint: .leading)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(selected ? 0.25 : 0.08), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Panel

private struct ToolPanel: View {
    @Bindable var model: AppModel
    let kind: ToolKind

    var body: some View {
        let tools = model.tools
        VStack(spacing: Theme.Metrics.gridSpacing) {
            ToolHeader(model: model, kind: kind)
                .frame(height: 176)
            if tools.isRunning(kind) {
                ToolProgressCard(model: model, kind: kind)
            } else if !tools.hasOutput(kind) {
                ToolIdleCard(model: model, kind: kind)
            } else {
                SnapshotSafeScroll {
                    VStack(spacing: 8) {
                        switch kind {
                        case .large: FileList(model: model, files: tools.large.output ?? [], selection: Binding(get: { tools.largeSelection }, set: { tools.largeSelection = $0 }),
                                              dateLabel: { $0.lastUsedOrModified })
                        case .old: FileList(model: model, files: tools.old.output ?? [], selection: Binding(get: { tools.oldSelection }, set: { tools.oldSelection = $0 }),
                                            dateLabel: { $0.lastUsedOrModified })
                        case .downloads: FileList(model: model, files: tools.visibleDownloads.map(\.file),
                                                  selection: Binding(get: { tools.downloadsSelection }, set: { tools.downloadsSelection = $0 }), dateLabel: { $0.lastTouched },
                                                  installers: Set(tools.visibleDownloads.filter(\.isInstaller).map(\.id)))
                        case .duplicates: DuplicateList(model: model)
                        case .nodeModules: NodeModulesList(model: model)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct ToolHeader: View {
    @Bindable var model: AppModel
    let kind: ToolKind

    var body: some View {
        let tools = model.tools
        let selected = tools.selectedBytes(kind)
        GlassCard(kind.title, subtitle: kind.subtitle, systemImage: kind.systemImage, palette: kind.palette,
                  focus: .trailing, glow: 0.75, animated: model.animated) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Выбрано").font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                    let d = ByteDisplay(selected, gigabytes: 1)
                    DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .large)
                        .animation(Theme.Motion.count, value: selected)
                }
                VStack(alignment: .leading, spacing: 8) {
                    filters
                    if let found = tools.foundBytes(kind) {
                        Text("Найдено \(shortBytes(found)) · \(countText(tools.foundCount(kind) ?? 0))")
                            .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    PrimaryScanButton("В Корзину", subtitle: model.isDryRun ? "Тестовый режим" : "можно вернуть",
                                      palette: kind.palette, animated: model.animated) {
                        model.confirmToolClean(tools.requests(for: kind), from: kind)
                    }
                    .frame(width: 250)
                    .disabled(selected == 0)
                    .opacity(selected == 0 ? 0.45 : 1)
                    if tools.isRunning(kind) {
                        PillButton("Остановить", systemImage: "stop.fill") { tools.cancel(kind) }
                    } else {
                        PillButton(tools.hasOutput(kind) ? "Искать заново" : "Искать", systemImage: "arrow.clockwise") { tools.run(kind) }
                    }
                }
            }
        }
    }

    private func countText(_ n: Int) -> String {
        switch kind {
        case .duplicates: plural(n, "группа", "группы", "групп")
        case .nodeModules: plural(n, "проект", "проекта", "проектов")
        default: plural(n, "файл", "файла", "файлов")
        }
    }

    @ViewBuilder private var filters: some View {
        let tools = model.tools
        switch kind {
        case .large:
            ChipRow(options: [(100, "100 МБ"), (250, "250 МБ"), (500, "500 МБ"), (1000, "1 ГБ"), (5000, "5 ГБ")],
                    selection: Binding(get: { tools.largeMinMB }, set: { tools.largeMinMB = $0; tools.run(.large) }),
                    label: "Больше")
        case .old:
            ChipRow(options: [(180, "полгода"), (365, "год"), (730, "2 года")],
                    selection: Binding(get: { tools.oldDays }, set: { tools.oldDays = $0; tools.run(.old) }),
                    label: "Не открывали")
        case .downloads:
            ChipRow(options: [(DownloadsFilter.olderThan(days: 30), "старше 30 дней"), (.olderThan(days: 90), "старше 90 дней"),
                              (.installers, "установщики"), (.all, "всё")],
                    selection: Binding(get: { tools.downloadsFilter }, set: { tools.downloadsFilter = $0; tools.downloadsSelection = [] }),
                    label: nil)
        case .nodeModules:
            ChipRow(options: [(30, "30 дней"), (90, "90 дней"), (0, "все")],
                    selection: Binding(get: { tools.nodeDays }, set: { tools.nodeDays = $0; tools.run(.nodeModules) }),
                    label: "Проект не трогали")
        case .duplicates:
            Text("Размер → начало и конец файла → полный SHA-256. Одна копия всегда остаётся.")
                .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(2).frame(maxWidth: 360, alignment: .leading)
        }
    }
}

/// Small filter chips.
struct ChipRow<Value: Equatable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    let label: String?

    var body: some View {
        HStack(spacing: 6) {
            if let label {
                Text(label).font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
            }
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let on = value == selection
                Button { withAnimation(Theme.Motion.snappy) { selection = value } } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 26)
                        .foregroundStyle(on ? Color.black : .white.opacity(0.85))
                        .background(Capsule().fill(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.3))))
                        .overlay(Capsule().strokeBorder(.white.opacity(on ? 0 : 0.14), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ToolProgressCard: View {
    @Bindable var model: AppModel
    let kind: ToolKind
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let p = model.tools.progress(kind)
        let visited = p?.filesVisited ?? 0
        GlassCard("Ищу", subtitle: phaseTitle(p?.phase), palette: kind.palette,
                  focus: .bottom, glow: 0.5, animated: model.animated) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom, spacing: 30) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Просмотрено файлов").font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                        DotMatrixNumber(Double(visited), style: .hero)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Найдено").font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                        let d = ByteDisplay(p?.bytesFound ?? 0, gigabytes: 1)
                        DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .large)
                    }
                }
                RunningScale(progress: min(0.95, log10(Double(visited) + 1) / 6), animated: model.animated)
                Text(isSnapshot ? "~/…" : (p?.currentPath.map(abbreviatePath) ?? " "))
                    .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                PillButton("Остановить", systemImage: "stop.fill") { model.tools.cancel(kind) }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Core reports phases in English ("scan", "quick-hash 3/40", "full-hash …").
func phaseTitle(_ phase: String?) -> String {
    guard let phase, !phase.isEmpty else { return "Обхожу домашнюю папку" }
    if phase.contains("hash") {
        let tail = phase.split(separator: " ").dropFirst().joined(separator: " ")
        return "Сравниваю содержимое" + (tail.isEmpty ? "" : " · " + tail)
    }
    return "Обхожу домашнюю папку"
}

private struct ToolIdleCard: View {
    @Bindable var model: AppModel
    let kind: ToolKind

    var body: some View {
        GlassCard(nil, palette: kind.palette, focus: .bottom, glow: 0.35, animated: model.animated) {
            VStack(spacing: 14) {
                DotMatrixText("--", style: .hero.dimmed)
                Text("Только смотрим: ничего не удаляется, пока ты сам не выберешь и не подтвердишь.")
                    .font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
                PillButton("Искать", systemImage: "magnifyingglass", selected: true) { model.tools.run(kind) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Lists

/// Files with checkboxes, sorted as given (biggest / oldest first).
private struct FileList: View {
    @Bindable var model: AppModel
    let files: [ToolFile]
    @Binding var selection: Set<String>
    let dateLabel: (ToolFile) -> Date?
    var installers: Set<String> = []
    @State private var limit = 150

    var body: some View {
        if files.isEmpty {
            EmptyToolList()
        } else {
            VStack(spacing: 0) {
                HStack {
                    Button(allSelected ? "Снять все" : "Выбрать все") {
                        selection = allSelected ? [] : Set(files.map(\.path))
                    }
                    .buttonStyle(.plain).font(Theme.Fonts.footer).foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Text("Личные файлы: отмечай сам, уходят в Корзину")
                        .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textTertiary)
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                ForEach(files.prefix(limit)) { f in
                    ToolFileRow(file: f, selected: selection.contains(f.path), date: dateLabel(f),
                                badge: installers.contains(f.path) ? "установщик" : nil) {
                        if selection.contains(f.path) { selection.remove(f.path) } else { selection.insert(f.path) }
                    }
                }
                if files.count > limit {
                    Button("Показать ещё \(min(300, files.count - limit))") { limit += 300 }
                        .buttonStyle(.plain).font(Theme.Fonts.footer).foregroundStyle(.white.opacity(0.7)).padding(10)
                }
            }
            .modifier(ListPanel())
        }
    }

    private var allSelected: Bool { !files.isEmpty && files.allSatisfy { selection.contains($0.path) } }
}

struct ToolFileRow: View {
    let file: ToolFile
    let selected: Bool
    let date: Date?
    var badge: String? = nil
    var keepButton: (() -> Void)? = nil
    var isKept = false
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if isKept {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.Colors.safe)
                    .frame(width: 18, height: 18)
            } else {
                CheckBox(state: selected ? .on : .off, enabled: true, tint: Theme.Colors.personal, size: 18, action: toggle)
            }
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.Colors.textTertiary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(file.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                    if let badge {
                        Text(badge).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).frame(height: 16)
                            .background(Capsule().fill(.white.opacity(0.1))).foregroundStyle(.white.opacity(0.75))
                    }
                    if isKept {
                        Text("оставляем").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).frame(height: 16)
                            .background(Capsule().fill(Theme.Colors.safe.opacity(0.2))).foregroundStyle(Theme.Colors.safe)
                    }
                }
                Text(abbreviatePath(file.path)).font(.system(size: 11)).foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let keepButton, !isKept {
                Button("Оставить эту", action: keepButton)
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Capsule().fill(.white.opacity(0.08))).foregroundStyle(.white.opacity(0.8))
            }
            if let date {
                Text(date, format: .relative(presentation: .named))
                    .font(.system(size: 11)).foregroundStyle(Theme.Colors.textTertiary)
                    .frame(width: 120, alignment: .trailing)
            }
            Text(shortBytes(file.bytes))
                .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                .frame(width: 76, alignment: .trailing)
            IconButton(systemImage: "eye", help: "Быстрый просмотр") { QuickLook.shared.preview(file.url) }
            IconButton(systemImage: "folder", help: "Показать в Finder") { QuickLook.reveal(file.url) }
        }
        .padding(.horizontal, 18).padding(.vertical, 7)
        .background(hovering ? Color.white.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Быстрый просмотр") { QuickLook.shared.preview(file.url) }
            Button("Показать в Finder") { QuickLook.reveal(file.url) }
        }
    }

    private var icon: String {
        switch (file.name as NSString).pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "avi", "mkv": "film"
        case "jpg", "jpeg", "png", "heic", "psd", "tif", "tiff": "photo"
        case "zip", "rar", "7z", "gz", "tar": "doc.zipper"
        case "dmg", "pkg", "iso": "opticaldiscdrive"
        case "mp3", "wav", "aif", "aiff", "m4a": "waveform"
        case "": "folder"
        default: "doc"
        }
    }
}

private struct DuplicateList: View {
    @Bindable var model: AppModel

    var body: some View {
        let tools = model.tools
        let groups = (tools.duplicates.output ?? []).sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        if groups.isEmpty {
            EmptyToolList()
        } else {
            ForEach(groups.prefix(80)) { g in
                let keepPath = tools.keep[g.id] ?? g.keep.path
                VStack(spacing: 0) {
                    HStack {
                        Text(g.files.first?.name ?? "").font(Theme.Fonts.title(14)).foregroundStyle(.white).lineLimit(1)
                        Text("\(plural(g.files.count, "копия", "копии", "копий")) по \(shortBytes(g.size))")
                            .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                        Spacer()
                        Text("освободится \(shortBytes(g.reclaimableBytes))")
                            .font(Theme.Fonts.footer).foregroundStyle(ToolKind.duplicates.palette.accent)
                    }
                    .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
                    ForEach(g.files) { f in
                        ToolFileRow(file: f, selected: tools.duplicateSelection.contains(f.path), date: f.lastUsedOrModified,
                                    keepButton: { withAnimation(Theme.Motion.snappy) { tools.setKeep(f, in: g) } },
                                    isKept: f.path == keepPath) {
                            if tools.duplicateSelection.contains(f.path) { tools.duplicateSelection.remove(f.path) }
                            else { tools.duplicateSelection.insert(f.path) }
                        }
                    }
                }
                .padding(.bottom, 6)
                .modifier(ListPanel(tint: ToolKind.duplicates.palette.primary))
            }
        }
    }
}

private struct NodeModulesList: View {
    @Bindable var model: AppModel

    var body: some View {
        let tools = model.tools
        let projects = (tools.nodeModules.output?.projects ?? []).sorted { $0.bytes > $1.bytes }
        if projects.isEmpty {
            EmptyToolList()
        } else {
            VStack(spacing: 0) {
                ForEach(projects) { p in
                    HStack(spacing: 12) {
                        CheckBox(state: tools.nodeSelection.contains(p.id) ? .on : .off, enabled: true,
                                 tint: ToolKind.nodeModules.palette.primary, size: 18) {
                            if tools.nodeSelection.contains(p.id) { tools.nodeSelection.remove(p.id) } else { tools.nodeSelection.insert(p.id) }
                        }
                        Image(systemName: "shippingbox").foregroundStyle(Theme.Colors.textTertiary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                            Text(abbreviatePath(p.projectPath)).font(.system(size: 11)).foregroundStyle(Theme.Colors.textTertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if let d = p.projectLastModified {
                            Text("проект менялся \(d.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 11)).foregroundStyle(Theme.Colors.textTertiary)
                        }
                        Text(shortBytes(p.bytes))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                            .frame(width: 76, alignment: .trailing)
                        if let url = p.item.url {
                            IconButton(systemImage: "folder", help: "Показать в Finder") { QuickLook.reveal(url) }
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8)
                }
                Text("После очистки: `npm install` в проекте вернёт зависимости.")
                    .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textTertiary).padding(12)
            }
            .modifier(ListPanel(tint: ToolKind.nodeModules.palette.primary))
        }
    }
}

private struct EmptyToolList: View {
    var body: some View {
        VStack(spacing: 10) {
            DotMatrixText("0", style: .large)
            Text("Ничего не нашлось — и это хорошо.").font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
        .modifier(ListPanel())
    }
}

private struct ListPanel: ViewModifier {
    var tint: Color = .white
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Theme.Colors.cardBase
                    LinearGradient(colors: [tint.opacity(0.08), .clear], startPoint: .top, endPoint: .center)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}
