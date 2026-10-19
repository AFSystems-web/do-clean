import SwiftUI
import DoCleanCore

// MARK: - Preview «было → станет»

struct PreviewStage: View {
    @Bindable var model: AppModel
    @Bindable var s: StructurizeModel

    var body: some View {
        let g = Theme.Metrics.gridSpacing
        VStack(spacing: g) {
            PreviewHeader(model: model, s: s).frame(height: 150)
            if s.planning {
                GlassCard("Смотрю, что где лежит", subtitle: "Только читаю — ничего не двигаю", palette: s.draft.palette,
                          focus: .bottom, glow: 0.5, animated: model.animated) {
                    RunningScale(progress: 0.5, animated: model.animated).frame(maxHeight: .infinity)
                }
            } else if let error = s.planError {
                GlassCard("Не получилось", subtitle: error, palette: .trash, animated: model.animated) { EmptyView() }
            } else if let plan = s.plan {
                if plan.moves.isEmpty {
                    GlassCard("Здесь уже порядок", subtitle: "Нечего раскладывать с этим пресетом", palette: .system,
                              focus: .bottom, glow: 0.6, animated: model.animated) {
                        DotMatrixText("0", style: .hero).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        BeforeColumn(plan: plan, animated: model.animated)
                        FlyingDots(color: s.draft.palette.accent, animated: model.animated).frame(width: 70)
                        AfterColumn(plan: plan, palette: s.draft.palette, animated: model.animated)
                    }
                }
            }
        }
    }
}

private struct PreviewHeader: View {
    @Bindable var model: AppModel
    @Bindable var s: StructurizeModel

    var body: some View {
        let plan = s.plan
        GlassCard(nil, palette: s.draft.palette, focus: .trailing, glow: 0.7, animated: model.animated) {
            HStack(alignment: .center, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Разложу").font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
                    HStack(alignment: .lastTextBaseline, spacing: 10) {
                        DotMatrixNumber(Double(plan?.count ?? 0), style: .hero)
                        Text(plan.map { pluralWord($0.count, "файл", "файла", "файлов") } ?? "")
                            .font(Theme.Fonts.title(18)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("«\(s.draft.title.ru)» · \(s.sources.map(\.title).joined(separator: ", "))")
                        .font(Theme.Fonts.cardTitle).foregroundStyle(.white)
                    if let plan {
                        Text("\(shortBytes(plan.bytes)) · \(plural(plan.newFolders.count, "новая папка", "новые папки", "новых папок"))")
                            .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                        SkippedChips(plan: plan)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 10) {
                    PrimaryScanButton("Разложить", subtitle: model.isDryRun ? "Тестовый режим" : "Можно отменить",
                                      palette: s.draft.palette, animated: model.animated) { s.confirming = true }
                        .frame(width: 280)
                        .disabled(plan?.moves.isEmpty ?? true)
                        .opacity(plan?.moves.isEmpty ?? true ? 0.45 : 1)
                    HStack(spacing: 8) {
                        PillButton("Назад", systemImage: "chevron.left") { withAnimation(Theme.Motion.spring) { s.stage = .choose } }
                        PillButton("Настроить", systemImage: "slider.horizontal.3") { withAnimation(Theme.Motion.spring) { s.stage = .customize } }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// «Остаются на месте»: skipped reasons as small chips.
private struct SkippedChips: View {
    let plan: MovePlan

    var body: some View {
        let groups = Dictionary(grouping: plan.skipped, by: \.reason)
            .filter { $0.key != .noRule }
            .sorted { $0.value.count > $1.value.count }
            .prefix(4)
        if !groups.isEmpty {
            HStack(spacing: 6) {
                Text("Остаются:").font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textTertiary)
                ForEach(groups, id: \.key) { reason, items in
                    HStack(spacing: 4) {
                        if reason == .projectUnit || reason == .projectFile { Image(systemName: "lock.fill").font(.system(size: 9)) }
                        Text("\(reason.title) · \(items.count)")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(.black.opacity(0.35)))
                    .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }
}

private struct BeforeColumn: View {
    let plan: MovePlan
    let animated: Bool

    var body: some View {
        GlassCard("Было", subtitle: "Сейчас лежит в корне", systemImage: "tray.full.fill", animated: animated) {
            SnapshotSafeScroll {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.sources, id: \.self) { root in
                        let moves = plan.moves.filter { $0.root == root }
                        let stays = plan.skipped.filter { $0.path.hasPrefix(root + "/") && ($0.reason == .projectUnit || $0.reason == .projectFile) }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.white.opacity(0.6))
                                Text(displayFolderName(root)).font(Theme.Fonts.title(14)).foregroundStyle(.white)
                                Text(plural(moves.count + stays.count, "объект", "объекта", "объектов"))
                                    .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textTertiary)
                            }
                            .padding(.bottom, 4)
                            ForEach(moves.prefix(28)) { m in
                                LeafRow(name: m.name, bytes: m.bytes, isFolder: m.isDirectory,
                                        badge: m.isUnit ? "переедет целиком" : nil)
                            }
                            ForEach(stays.prefix(6)) { e in
                                LeafRow(name: e.name, bytes: nil, isFolder: e.reason == .projectUnit, badge: "остаётся на месте")
                            }
                            if moves.count > 28 {
                                Text("и ещё \(moves.count - 28)").font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textTertiary)
                                    .padding(.leading, 26)
                            }
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
    }
}

private struct AfterColumn: View {
    let plan: MovePlan
    let palette: Palette
    let animated: Bool
    @State private var shown = false

    var body: some View {
        GlassCard("Станет", subtitle: "Новые папки и что в них", systemImage: "folder.fill.badge.plus",
                  palette: palette, focus: .bottomTrailing, glow: 0.55, animated: animated) {
            SnapshotSafeScroll {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.afterTree) { root in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.white.opacity(0.6))
                                Text(displayFolderName(root.id)).font(Theme.Fonts.title(14)).foregroundStyle(.white)
                            }
                            .padding(.bottom, 4)
                            let folders = root.children.filter(\.isFolder).filter { $0.move == nil }
                            ForEach(Array(folders.enumerated()), id: \.element.id) { i, node in
                                FolderNode(node: node, depth: 0, palette: palette)
                                    .opacity(shown ? 1 : 0)
                                    .offset(x: shown ? 0 : -40)
                                    .animation(Theme.Motion.spring.delay(Double(i) * 0.06), value: shown)
                            }
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .onAppear { if animated { shown = true } }
        .onChange(of: animated, initial: true) { _, a in if !a { shown = true } }
    }
}

/// A target folder with counters and its first few items.
private struct FolderNode: View {
    let node: PlanTreeNode
    let depth: Int
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").font(.system(size: 13)).foregroundStyle(palette.accent)
                    .shadow(color: palette.primary.opacity(0.8), radius: 4)
                Text(node.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Text("\(node.count) · \(shortBytes(node.bytes))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.65))
            }
            .padding(.leading, CGFloat(depth) * 18)
            let subfolders = node.children.filter { $0.move == nil }
            ForEach(subfolders.prefix(depth == 0 ? 4 : 2)) { c in
                FolderNode(node: c, depth: depth + 1, palette: palette)
            }
            let leaves = node.children.compactMap(\.move)
            ForEach(leaves.prefix(depth == 0 ? 3 : 2)) { m in
                LeafRow(name: m.destinationName, bytes: m.bytes, isFolder: m.isDirectory,
                        badge: m.isUnit ? "переедет целиком" : nil)
                    .padding(.leading, CGFloat(depth + 1) * 18)
            }
            if leaves.count > (depth == 0 ? 3 : 2) {
                Text("+ ещё \(leaves.count - (depth == 0 ? 3 : 2))").font(.system(size: 11)).foregroundStyle(Theme.Colors.textTertiary)
                    .padding(.leading, CGFloat(depth + 1) * 18 + 26)
            }
        }
    }
}

private struct LeafRow: View {
    let name: String
    let bytes: Int64?
    let isFolder: Bool
    let badge: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isFolder ? "folder" : icon).font(.system(size: 11)).foregroundStyle(Theme.Colors.textTertiary)
                .frame(width: 18)
            Text(name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).truncationMode(.middle)
            if let badge {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill").font(.system(size: 8))
                    Text(badge)
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).frame(height: 17)
                .background(Capsule().fill(Theme.Colors.review.opacity(0.18)))
                .foregroundStyle(Theme.Colors.review)
            }
            Spacer(minLength: 6)
            if let bytes {
                Text(shortBytes(bytes)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .frame(height: 20)
    }

    private var icon: String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "mkv", "avi": "film"
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "psd", "tif", "tiff": "photo"
        case "zip", "rar", "7z", "gz": "doc.zipper"
        case "dmg", "pkg", "iso": "opticaldiscdrive"
        case "mp3", "wav", "m4a", "aif", "aiff", "flac": "waveform"
        case "pdf", "doc", "docx", "pages", "txt", "md": "doc.text"
        default: "doc"
        }
    }
}

/// Little dots flying from «было» to «станет». Static (a dotted arrow) without motion.
private struct FlyingDots: View {
    let color: Color
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = !animated || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { ctx in
            let t = still ? 0.37 : ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let midY = size.height * 0.42
                for i in 0..<14 {
                    let seed = Double(i) * 1.618
                    let p = (t * 0.45 + seed).truncatingRemainder(dividingBy: 1)
                    let x = 6 + p * (size.width - 12)
                    let y = midY + sin(seed * 5) * size.height * 0.28 * (1 - p)
                    let a = sin(p * .pi)
                    let r = 2.0 + (1 - p) * 1.5
                    g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(a)))
                }
                var arrow = Path()
                arrow.move(to: CGPoint(x: size.width - 20, y: midY - 7))
                arrow.addLine(to: CGPoint(x: size.width - 10, y: midY))
                arrow.addLine(to: CGPoint(x: size.width - 20, y: midY + 7))
                g.stroke(arrow, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// «Desktop» → «Рабочий стол» for the well-known home folders.
func displayFolderName(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return ["Desktop": "Рабочий стол", "Downloads": "Загрузки", "Documents": "Документы",
            "Movies": "Фильмы", "Pictures": "Изображения", "Music": "Музыка"][name] ?? name
}

func pluralWord(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let s = plural(n, one, few, many)
    return String(s.drop { $0 != " " }.dropFirst())
}

// MARK: - Confirm

struct StructurizeConfirmSheet: View {
    @Bindable var model: AppModel
    @Bindable var s: StructurizeModel

    var body: some View {
        let plan = s.plan
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Разложить?").font(Theme.Fonts.title(24)).foregroundStyle(.white)
                    Text("«\(s.draft.title.ru)» · \(s.sources.map(\.title).joined(separator: ", "))")
                        .font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                DotMatrixNumber(Double(plan?.count ?? 0), style: .large)
            }
            if model.isDryRun {
                Notice(color: Theme.Colors.review, systemImage: "testtube.2",
                       text: "Тестовый режим: ничего не переместится. Покажу, как бы разложилось.")
            }
            Notice(color: Theme.Colors.safe, systemImage: "arrow.uturn.backward.circle",
                   text: "Ничего не удаляется. Всё записывается в журнал — «Отменить раскладку» вернёт как было.")
            if let plan {
                VStack(spacing: 6) {
                    ForEach(plan.summary().prefix(7), id: \.folder) { row in
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(s.draft.palette.accent)
                            Text(row.folder).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            Spacer()
                            Text("\(row.count) · \(shortBytes(row.bytes))")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                        }
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.04)))
                    }
                }
                let units = plan.moves.filter(\.isUnit).count
                if units > 0 {
                    Label("\(plural(units, "проект переедет", "проекта переедут", "проектов переедут")) целиком — внутрь не лезу",
                          systemImage: "lock.fill")
                        .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.review)
                }
            }
            HStack {
                PillButton("Отмена") { s.confirming = false }.keyboardShortcut(.cancelAction)
                Spacer()
                PrimaryScanButton("Разложить", subtitle: model.isDryRun ? "Тестовый режим" : "Можно отменить",
                                  palette: s.draft.palette, animated: model.animated) { s.apply() }
                    .frame(width: 300)
            }
        }
        .padding(28)
        .frame(width: 600)
        .background(Color(hex: 0x16161A))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Applying / done

struct ApplyingStage: View {
    @Bindable var model: AppModel
    @Bindable var s: StructurizeModel

    var body: some View {
        let total = max(1, s.plan?.count ?? 1)
        GlassCard(model.isDryRun ? "Проверяю раскладку" : "Раскладываю", subtitle: "Каждое перемещение — в журнал",
                  systemImage: "square.stack.3d.up.fill", palette: s.draft.palette, focus: .bottom,
                  glow: 0.4 + 0.6 * Double(s.appliedCount) / Double(total), animated: model.animated) {
            VStack(alignment: .leading, spacing: 20) {
                Spacer()
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    DotMatrixText("\(s.appliedCount)/\(total)", style: DotMatrixStyle(dotSize: 8, spacing: 2.8))
                    Text("файлов").font(Theme.Fonts.title(18)).foregroundStyle(.white.opacity(0.7))
                }
                RunningScale(progress: Double(s.appliedCount) / Double(total), animated: model.animated)
                Text(s.currentName.map { "Сейчас: \($0)" } ?? "Готовлю…")
                    .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary).lineLimit(1)
            }
        }
    }
}

struct DoneStage: View {
    @Bindable var model: AppModel
    @Bindable var s: StructurizeModel

    var body: some View {
        let r = s.report
        let dry = r?.dryRun ?? model.isDryRun
        let journal = s.lastJournal
        let undone = journal?.isUndone ?? false
        GlassCard(nil, palette: s.draft.palette, focus: .bottom, glow: 0.6, animated: model.animated) {
            ZStack {
                CalmCelebration(animated: model.animated)
                VStack(spacing: 22) {
                    Text(undone ? "Вернул как было" : (dry ? "Так бы разложилось" : "Готово, порядок"))
                        .font(Theme.Fonts.title(24)).foregroundStyle(.white)
                    HStack(alignment: .lastTextBaseline, spacing: 12) {
                        DotMatrixNumber(Double(undone ? (s.undoReport?.restored ?? 0) : (r?.moved.count ?? 0)),
                                        style: DotMatrixStyle(dotSize: 10, spacing: 3.4))
                        Text(undone ? "на месте" : "файлов по папкам").font(Theme.Fonts.title(18)).foregroundStyle(.white.opacity(0.8))
                    }
                    if let plan = s.plan, !undone {
                        HStack(spacing: 8) {
                            ForEach(plan.summary().prefix(6), id: \.folder) { row in
                                HStack(spacing: 5) {
                                    Image(systemName: "folder.fill").foregroundStyle(s.draft.palette.accent)
                                    Text("\(row.folder) · \(row.count)")
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(Capsule().fill(.black.opacity(0.4)))
                                .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                    }
                    if let r, !r.failed.isEmpty || !r.skipped.isEmpty {
                        Text("Пропущено \(r.skipped.count + r.failed.count): изменились или заняты — остались на месте")
                            .font(Theme.Fonts.footer).foregroundStyle(.white.opacity(0.7))
                    }
                    PrimaryScanButton(undone ? "Отменено" : "Отменить раскладку",
                                      subtitle: dry ? "В тестовом режиме отменять нечего" :
                                        (s.undoing ? "Возвращаю…" : "Всё вернётся на прежние места"),
                                      palette: .trash, animated: model.animated) {
                        if let journal { s.undo(journal) }
                    }
                    .frame(width: 380)
                    .disabled(journal == nil || undone || s.undoing)
                    .opacity(journal == nil || undone ? 0.5 : 1)
                    HStack(spacing: 10) {
                        PillButton("Ещё раз", systemImage: "arrow.counterclockwise", selected: true) { s.restart() }
                        if dry { DryRunBadge() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - History

struct LayoutHistoryCard: View {
    @Bindable var model: AppModel
    @Bindable var s: StructurizeModel

    var body: some View {
        GlassCard("История раскладок", subtitle: s.journals.isEmpty ? "Раскладок ещё не было" : "Любую можно отменить",
                  systemImage: "clock.arrow.circlepath", animated: model.animated) {
            SnapshotSafeScroll {
                VStack(spacing: 6) {
                    ForEach(s.journals.prefix(20)) { j in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(j.displayTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                    Text(j.sources.map(displayFolderName).joined(separator: ", "))
                                        .font(.system(size: 12)).foregroundStyle(Theme.Colors.textSecondary)
                                }
                                Text("\(j.date.formatted(.relative(presentation: .named))) · \(plural(j.moves.count, "файл", "файла", "файлов")) · \(shortBytes(j.bytes))")
                                    .font(.system(size: 11)).foregroundStyle(Theme.Colors.textTertiary)
                            }
                            Spacer()
                            if j.isUndone {
                                Text("отменено").font(Theme.Fonts.badge).padding(.horizontal, 8).frame(height: 22)
                                    .background(Capsule().fill(.white.opacity(0.08))).foregroundStyle(.white.opacity(0.6))
                            } else {
                                PillButton("Отменить", systemImage: "arrow.uturn.backward") { s.undo(j) }
                            }
                        }
                        .padding(.horizontal, 12).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.25)))
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}
