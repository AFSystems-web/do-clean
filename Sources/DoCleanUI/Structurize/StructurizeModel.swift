import SwiftUI
import DoCleanCore

/// Where to tidy up.
public enum StructureSource: Hashable, Sendable, Identifiable {
    case desktop, downloads, documents
    case custom(URL)

    public var id: String { url(home: URL(fileURLWithPath: "/")).path }

    public func url(home: URL) -> URL {
        switch self {
        case .desktop: home.appendingPathComponent("Desktop", isDirectory: true)
        case .downloads: home.appendingPathComponent("Downloads", isDirectory: true)
        case .documents: home.appendingPathComponent("Documents", isDirectory: true)
        case .custom(let u): u
        }
    }

    public var title: String {
        switch self {
        case .desktop: "Рабочий стол"
        case .downloads: "Загрузки"
        case .documents: "Документы"
        case .custom(let u): u.lastPathComponent
        }
    }
}

/// Steps of the «Порядок» flow.
public enum StructurizeStage: Equatable, Sendable {
    case choose, customize, preview, applying, done
}

/// State of the «Порядок» tab: sources, presets, the editable draft, plan, apply and undo.
@MainActor @Observable
public final class StructurizeModel {
    private unowned let app: AppModel

    public var stage: StructurizeStage = .choose
    public var sources: [StructureSource] = [.downloads]
    public var recursive = false
    public var selectedPresetID: String = StructurePreset.byTypeID
    /// Editable copy of the selected preset.
    public var draft: StructurePreset
    public var draftDirty = false

    public private(set) var planning = false
    public private(set) var plan: MovePlan?
    public private(set) var planError: String?

    public var confirming = false
    public internal(set) var appliedCount = 0
    public internal(set) var currentName: String?
    public private(set) var report: ApplyReport?
    public private(set) var undoReport: UndoReport?
    public private(set) var undoing = false
    public private(set) var journals: [StructureJournal] = []

    /// Snapshots: a journal store in a temp folder; nil = the real one.
    public var journalStoreOverride: JournalStore?

    init(app: AppModel) {
        self.app = app
        self.draft = StructurePreset.builtIn(language: app.settings.settings.language).first!
        reloadJournals()
    }

    public var isDryRun: Bool { app.isDryRun }
    var home: URL { app.environment.home }
    var executor: StructureExecutor { StructureExecutor(environment: app.scanEnvironment, journals: journalStoreOverride) }

    // MARK: Presets

    public var presets: [StructurePreset] { app.settings.settings.allStructurePresets() }

    public func select(_ preset: StructurePreset) {
        selectedPresetID = preset.id
        draft = preset
        draftDirty = false
        plan = nil
    }

    public func toggleSource(_ s: StructureSource) {
        if let i = sources.firstIndex(of: s) {
            if sources.count > 1 { sources.remove(at: i) }
        } else {
            sources.append(s)
        }
        plan = nil
    }

    public func addCustomSource(_ url: URL) {
        let s = StructureSource.custom(url)
        if !sources.contains(s) { sources.append(s) }
        plan = nil
    }

    // MARK: Draft editing

    public func updateRule(_ rule: StructureRule) {
        guard let i = draft.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        draft.rules[i] = rule
        draftDirty = true
        plan = nil
    }

    public func addRule() {
        draft.rules.append(StructureRule(name: "Новое правило", extensions: [], target: "Разное"))
        draftDirty = true
        plan = nil
    }

    public func removeRule(_ id: String) {
        draft.rules.removeAll { $0.id == id }
        draftDirty = true
        plan = nil
    }

    public func updateLayout(_ layout: ProjectLayout) {
        draft.projectLayout = layout
        draftDirty = true
        plan = nil
    }

    /// Saves the draft as a user preset (stored in settings.json).
    @discardableResult
    public func saveDraftAsPreset(named name: String) -> StructurePreset {
        let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? draft.title.ru + " (моя)" : name
        let copy = draft.duplicated(title: L10n(ru: title, en: title))
        app.settings.settings.structurePresets.append(copy)
        select(copy)
        return copy
    }

    public func deleteUserPreset(_ id: String) {
        app.settings.settings.structurePresets.removeAll { $0.id == id }
        if selectedPresetID == id, let first = presets.first { select(first) }
    }

    /// «mp4 mov *.braw» → extensions + globs.
    public static func parseMask(_ text: String) -> (extensions: [String], globs: [String]) {
        var ext: [String] = [], globs: [String] = []
        for raw in text.split(whereSeparator: { $0 == " " || $0 == "," }) {
            let t = String(raw).trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if t.contains("*") || t.contains("?") { globs.append(t) }
            else { ext.append(t.hasPrefix(".") ? String(t.dropFirst()).lowercased() : t.lowercased()) }
        }
        return (ext, globs)
    }

    public static func maskText(_ rule: StructureRule) -> String {
        if rule.matchesAll && rule.extensions.isEmpty && rule.globs.isEmpty { return "все файлы" }
        return (rule.extensions + rule.globs).joined(separator: " ")
    }

    // MARK: Plan

    public func makePlan() {
        let urls = sources.map { $0.url(home: home) }
        let preset = draft
        let options = PlanOptions(recursive: recursive, language: app.settings.settings.language)
        let planner = StructurePlanner(environment: app.scanEnvironment)
        planning = true
        planError = nil
        withAnimation(Theme.Motion.spring) { stage = .preview }
        Task { [weak self] in
            do {
                let p = try await planner.plan(sources: urls, preset: preset, options: options)
                self?.installPlan(p)
            } catch {
                self?.planning = false
                self?.planError = "\(error)"
            }
        }
    }

    /// Installs a plan (also used by snapshots).
    public func installPlan(_ p: MovePlan) {
        plan = p
        planning = false
        withAnimation(Theme.Motion.spring) { stage = .preview }
    }

    // MARK: Apply / undo

    public func apply() {
        guard let plan, !plan.moves.isEmpty || !plan.newFolders.isEmpty else { return }
        confirming = false
        appliedCount = 0
        currentName = nil
        report = nil
        undoReport = nil
        let dryRun = isDryRun
        let exec = executor
        withAnimation(Theme.Motion.spring) { stage = .applying }
        let sink = MoveSink { [weak self] m in
            self?.appliedCount += 1
            self?.currentName = m.name
        }
        Task { [weak self] in
            let r = await exec.apply(plan, dryRun: dryRun) { m in sink.send(m) }
            try? await Task.sleep(for: .milliseconds(250))
            self?.finishApply(r)
        }
    }

    public func finishApply(_ r: ApplyReport) {
        report = r
        appliedCount = r.moved.count
        reloadJournals()
        withAnimation(Theme.Motion.spring) { stage = .done }
    }

    /// The journal of the last real apply, if it can still be undone.
    public var lastJournal: StructureJournal? {
        guard let id = report?.journalID else { return nil }
        return journals.first { $0.id == id }
    }

    public func undo(_ journal: StructureJournal) {
        guard !journal.isUndone else { return }
        undoing = true
        let exec = executor
        let dryRun = isDryRun
        Task { [weak self] in
            let r = await exec.undo(journal, dryRun: dryRun)
            self?.undoReport = r
            self?.undoing = false
            self?.reloadJournals()
        }
    }

    public func reloadJournals() {
        journals = (journalStoreOverride ?? JournalStore.default(home: home)).list()
    }

    public func restart() {
        plan = nil
        report = nil
        undoReport = nil
        withAnimation(Theme.Motion.spring) { stage = .choose }
    }
}

private final class MoveSink: Sendable {
    private let handler: @MainActor @Sendable (PlannedMove) -> Void
    init(_ handler: @escaping @MainActor @Sendable (PlannedMove) -> Void) { self.handler = handler }
    func send(_ m: PlannedMove) {
        let handler = handler
        Task { @MainActor in handler(m) }
    }
}

// MARK: - Presentation helpers

public extension StructurePreset {
    /// Card colour: built-ins have fixed palettes, user presets rotate.
    var palette: Palette {
        switch id {
        case StructurePreset.byTypeID: .xcode
        case StructurePreset.byDateID: .ai
        case StructurePreset.creativeID: .adobe
        case StructurePreset.minimalID: .system
        default: [Palette.personal, .downloads, .trash][id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 3]
        }
    }

    var systemImage: String {
        switch id {
        case StructurePreset.byTypeID: "square.grid.2x2.fill"
        case StructurePreset.byDateID: "calendar"
        case StructurePreset.creativeID: "film.stack"
        case StructurePreset.minimalID: "tray.2.fill"
        default: "star.fill"
        }
    }

    /// A few lines for the tiny folder-tree preview on the card: (depth, name).
    func treePreview(language: Language = .ru, limit: Int = 5) -> [(depth: Int, name: String)] {
        if strategy == .creative, let l = projectLayout {
            return [(0, l.root), (1, language == .ru ? "Клип для Nike" : "Nike clip"), (2, l.sources), (2, l.renders), (2, l.exports)]
        }
        let now = Date()
        func expand(_ t: String) -> String {
            let c = Calendar.current.dateComponents([.year, .month], from: now)
            let f = DateFormatter()
            f.locale = Locale(identifier: language == .ru ? "ru_RU" : "en_US")
            let month = f.standaloneMonthSymbols[(c.month ?? 1) - 1].capitalized
            return t.replacingOccurrences(of: "{year}", with: String(c.year ?? 2026))
                .replacingOccurrences(of: "{month}", with: String(format: "%02d", c.month ?? 1))
                .replacingOccurrences(of: "{monthName}", with: month)
        }
        var lines: [(Int, String)] = []
        var seen = Set<String>()
        for r in rules where r.enabled {
            let parts = expand(r.target).split(separator: "/").map(String.init)
            for (d, p) in parts.enumerated() {
                let key = parts.prefix(d + 1).joined(separator: "/")
                if seen.insert(key).inserted { lines.append((d, p)) }
            }
            if lines.count >= limit { break }
        }
        for f in folders where lines.count < limit && seen.insert(f).inserted { lines.append((0, f)) }
        return Array(lines.prefix(limit))
    }
}

extension SkipReason {
    var title: String {
        switch self {
        case .hidden: "скрытые"
        case .symlink: "ссылки"
        case .bundle: "программы и бандлы"
        case .busy: "открыты сейчас"
        case .iCloudPlaceholder: "в iCloud"
        case .partialDownload: "докачиваются"
        case .excluded: "в исключениях"
        case .forbidden: "системные"
        case .projectUnit: "проекты (остаются целиком)"
        case .projectFile: "файлы проектов"
        case .alreadyInPlace: "уже на месте"
        case .noRule: "без правила"
        case .targetBlocked: "место занято"
        case .changed: "изменились"
        case .outsideSource: "вне папки"
        }
    }
}

extension StructureJournal {
    /// Journals store the English title; show the Russian one for built-ins.
    var displayTitle: String {
        let ru = StructurePreset.builtIn(language: .ru), en = StructurePreset.builtIn(language: .en)
        if let i = en.firstIndex(where: { $0.title.en == presetTitle }) { return ru[i].title.ru }
        return presetTitle
    }
}
