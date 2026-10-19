import SwiftUI
import AppKit
import DoCleanCore

/// Scan depth on the dashboard: which safety tiers get scanned.
public enum ScanMode: Int, CaseIterable, Sendable {
    case quick, deep, all

    public var title: String {
        switch self {
        case .quick: "Быстро"
        case .deep: "Глубоко"
        case .all: "Всё"
        }
    }

    public var hint: String {
        switch self {
        case .quick: "Только зелёное: кэши, которые программы пересоздадут сами"
        case .deep: "Зелёное и жёлтое: ещё модели, симуляторы, архивы, кэши пакетов"
        case .all: "Всё, включая личное: Загрузки и Корзину — только по одному файлу"
        }
    }

    public var tiers: Set<Tier> {
        switch self {
        case .quick: [.green]
        case .deep: [.green, .yellow]
        case .all: Set(Tier.allCases)
        }
    }
}

/// Top-level sections.
public enum AppSection: Int, CaseIterable, Sendable {
    case home, tools, structurize, history, settings

    public var title: String {
        switch self {
        case .home: "Главная"
        case .tools: "Инструменты"
        case .structurize: "Порядок"
        case .history: "История"
        case .settings: "Настройки"
        }
    }
}

/// Where the home flow is: dashboard → scanning → results → cleaning → finished.
public enum HomeStage: Equatable, Sendable {
    case dashboard, scanning, results, cleaning, finished
}

/// Free / total bytes of the start-up volume.
public struct DiskSpace: Equatable, Sendable {
    public var free: Int64
    public var total: Int64
    public var used: Int64 { max(0, total - free) }

    public init(free: Int64, total: Int64) {
        self.free = free
        self.total = total
    }

    public static func current(at path: String = "/") -> DiskSpace {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return DiskSpace(free: values?.volumeAvailableCapacityForImportantUsage ?? 0,
                         total: Int64(values?.volumeTotalCapacity ?? 0))
    }
}

/// App state for the screens. Owns the scan, the selection and the clean flow.
@MainActor @Observable
public final class AppModel {
    // Configuration
    public let environment: DoCleanEnvironment
    public let rules: [Rule]
    public let loadError: String?
    /// Real deletion is off unless the caller enables it (the app does, except with `-dry-run`).
    public let allowRealClean: Bool
    /// False in snapshots: no breathing, no count-up.
    public var animated = true

    // Navigation
    public var section: AppSection = .home
    public var stage: HomeStage = .dashboard
    public var mode: ScanMode = .deep

    // Disk
    public var disk: DiskSpace

    // Tools tab
    public let tools: ToolsModel

    // Scan
    public let scan = ScanModel()
    public private(set) var lastResult: ScanResult?
    /// Selected item ids per rule id.
    public var selection: [String: Set<String>] = [:]
    public var expanded: Set<String> = []

    // Clean
    public var confirming = false
    /// Set while a tool's selection goes through the clean flow.
    public private(set) var toolRequests: [CleanRequest]?
    public private(set) var cleanSourceTool: ToolKind?
    /// Tools whose results are stale after a real clean.
    public var toolsNeedRefresh: Set<ToolKind> = []
    private var cleanStartedFromSheet = false
    public internal(set) var cleanTotalItems = 0
    public internal(set) var cleanDoneItems = 0
    public internal(set) var cleanFreed: Int64 = 0
    public internal(set) var cleanCurrent: String?
    public private(set) var report: CleanReport?
    public internal(set) var diskBefore: DiskSpace?
    public private(set) var diskAfter: DiskSpace?
    private var cleanTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    /// «Порядок» tab (Structurize).
    public private(set) var structurize: StructurizeModel!

    // Settings (core model, saved to ~/Library/Application Support/do clean/settings.json)
    public let settings: SettingsModel
    /// Onboarding is shown until the user finishes it once.
    public var showOnboarding: Bool
    public static let onboardedKey = "doclean.onboarded"

    public init(environment: DoCleanEnvironment = .live(), rules: [Rule]? = nil,
                allowRealClean: Bool = false, disk: DiskSpace? = nil,
                settingsStore: SettingsStore? = nil, showOnboarding: Bool? = nil) {
        self.environment = environment
        self.settings = SettingsModel(store: settingsStore ?? SettingsStore(fileURL: SettingsStore.defaultURL(home: environment.home)))
        self.showOnboarding = showOnboarding ?? !UserDefaults.standard.bool(forKey: Self.onboardedKey)
        self.allowRealClean = allowRealClean
        self.disk = disk ?? DiskSpace.current()
        self.tools = ToolsModel(environment: environment)
        tools.largeMinMB = Int(settings.settings.largeFileThreshold / 1_000_000)
        let settingsModel = settings
        tools.exclusionsProvider = { settingsModel.settings }
        if let rules {
            self.rules = rules
            self.loadError = nil
        } else {
            do {
                self.rules = try RuleCatalog.loadWithUserRules()
                self.loadError = nil
            } catch {
                self.rules = []
                self.loadError = "\(error)"
            }
        }
        structurize = StructurizeModel(app: self)
    }

    public var isDryRun: Bool { !allowRealClean }

    public func refreshDisk() { disk = DiskSpace.current() }

    // MARK: Scan

    public var rulesForMode: [Rule] {
        let excluded = Set(settings.settings.excludedRuleIDs)
        return rules.filter { mode.tiers.contains($0.tier) && !excluded.contains($0.id) }
    }

    /// Environment with the user's exclusions.
    public var scanEnvironment: DoCleanEnvironment { environment.applying(settings.settings) }

    /// Snapshots/tests: history without touching the real file.
    public var historyEntriesOverride: [HistoryEntry]?

    public func historyStats() -> HistoryStats {
        if let o = historyEntriesOverride { return HistoryStats(entries: o, rules: rules) }
        return HistoryStats(history: History(fileURL: History.defaultURL(home: environment.home)), rules: rules)
    }

    /// Menu-bar «Быстрая чистка»: green-only scan, then Results (nothing is removed without confirmation).
    public func quickClean() {
        mode = .quick
        section = .home
        showOnboarding = false
        startScan()
    }

    public func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        withAnimation(Theme.Motion.spring) { showOnboarding = false }
    }

    public func startScan() {
        let rules = rulesForMode
        scan.start(rules: rules, environment: scanEnvironment)
        withAnimation(Theme.Motion.spring) { stage = .scanning }
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            // Poll the observable phase: move on when the scan ends.
            while let self, !Task.isCancelled {
                switch self.scan.phase {
                case .done:
                    if let r = self.scan.result { self.finishScan(r) }
                    return
                case .cancelled:
                    withAnimation(Theme.Motion.spring) { self.stage = .dashboard }
                    return
                default:
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
        }
    }

    public func cancelScan() {
        scan.cancel()
    }

    /// Installs a finished result (also used by snapshots and tests).
    public func finishScan(_ result: ScanResult) {
        lastResult = result
        selection = Self.defaultSelection(for: result)
        expanded = []
        withAnimation(Theme.Motion.spring) { stage = .results }
    }

    /// Green: all items selected. Yellow: nothing. Red: nothing, item by item only.
    public static func defaultSelection(for result: ScanResult) -> [String: Set<String>] {
        var s: [String: Set<String>] = [:]
        for r in result.results where r.isCleanable && r.rule.defaultSelected {
            s[r.id] = Set(r.items.map(\.id))
        }
        return s
    }

    // MARK: Selection

    public enum Check: Equatable { case none, some, all }

    public func check(_ r: RuleResult) -> Check {
        let n = selection[r.id]?.count ?? 0
        if n == 0 { return .none }
        return n >= r.items.count ? .all : .some
    }

    /// Rule-level toggle. Not allowed for red rules (item by item only) or blocked ones.
    public func canToggleRule(_ r: RuleResult) -> Bool { r.isCleanable && r.rule.tier != .red }

    public func toggleRule(_ r: RuleResult) {
        guard canToggleRule(r) else { return }
        selection[r.id] = check(r) == .all ? [] : Set(r.items.map(\.id))
    }

    public func isSelected(_ item: ScanItem, in r: RuleResult) -> Bool {
        selection[r.id]?.contains(item.id) ?? false
    }

    public func toggleItem(_ item: ScanItem, in r: RuleResult) {
        guard r.isCleanable else { return }
        var set = selection[r.id] ?? []
        if set.contains(item.id) { set.remove(item.id) } else { set.insert(item.id) }
        selection[r.id] = set
    }

    public func selectedBytes(_ r: RuleResult) -> Int64 {
        guard let set = selection[r.id], !set.isEmpty else { return 0 }
        return r.items.filter { set.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    public var selectedBytes: Int64 {
        lastResult?.results.reduce(0) { $0 + selectedBytes($1) } ?? 0
    }

    /// What the confirm/clean flow works on: a tool's requests, else the scan selection.
    public var requests: [CleanRequest] { toolRequests ?? scanRequests }

    /// Bytes of `requests`.
    public var requestedBytes: Int64 { requests.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.bytes } } }

    /// Clean requests from the current scan selection (cleanable rules only).
    public var scanRequests: [CleanRequest] {
        guard let result = lastResult else { return [] }
        return result.results.compactMap { r in
            guard r.isCleanable, let set = selection[r.id], !set.isEmpty else { return nil }
            let items = r.items.filter { set.contains($0.id) }
            return items.isEmpty ? nil : CleanRequest(rule: r.rule, items: items)
        }
    }

    public var selectedItemCount: Int { requests.reduce(0) { $0 + $1.items.count } }

    public func selectedBytes(tier: Tier) -> Int64 {
        requests.filter { $0.rule.tier == tier }.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.bytes } }
    }

    // MARK: Clean

    /// Tools hand their selection over here; the same confirm → clean → finish flow follows.
    public func confirmToolClean(_ reqs: [CleanRequest], from tool: ToolKind) {
        let nonEmpty = reqs.filter { !$0.items.isEmpty }
        guard !nonEmpty.isEmpty else { return }
        toolRequests = nonEmpty
        cleanSourceTool = tool
        cleanStartedFromSheet = false
        confirming = true
    }

    /// Sheet closed without cleaning.
    public func confirmDismissed() {
        if !cleanStartedFromSheet { toolRequests = nil; cleanSourceTool = nil }
        cleanStartedFromSheet = false
    }

    public func clean() {
        let reqs = requests
        guard !reqs.isEmpty else { return }
        cleanStartedFromSheet = true
        confirming = false
        let dryRun = isDryRun
        cleanTotalItems = reqs.reduce(0) { $0 + $1.items.count }
        cleanDoneItems = 0
        cleanFreed = 0
        cleanCurrent = nil
        report = nil
        refreshDisk()
        diskBefore = disk
        withAnimation(Theme.Motion.spring) {
            section = .home
            stage = .cleaning
        }

        // Real runs append to History inside Cleaner; dry runs never write history.
        let cleaner = Cleaner(environment: environment, settings: settings.settings,
                              history: dryRun ? nil : History(fileURL: History.defaultURL(home: environment.home)))
        cleanTask = Task { [weak self] in
            let sink = ProgressSink { [weak self] entry in self?.record(entry) }
            let report = await cleaner.clean(reqs, dryRun: dryRun) { entry in sink.send(entry) }
            // Let queued progress updates land first.
            try? await Task.sleep(for: .milliseconds(250))
            self?.finishClean(report)
        }
    }

    private func record(_ entry: CleanEntry) {
        cleanDoneItems += 1
        cleanFreed += entry.freedBytes
        cleanCurrent = entry.item.name
    }

    /// Installs a finished report (also used by snapshots).
    public func finishClean(_ report: CleanReport) {
        self.report = report
        cleanDoneItems = report.entries.count
        cleanFreed = report.freedBytes
        refreshDisk()
        let before = diskBefore ?? disk
        diskBefore = before
        // Dry run: the disk did not change, show the projected result.
        diskAfter = report.dryRun ? DiskSpace(free: before.free + report.freedBytes, total: before.total) : disk
        withAnimation(Theme.Motion.spring) { stage = .finished }
    }

    public func backToDashboard() {
        let realRun = report?.dryRun == false
        refreshDisk()
        if let tool = cleanSourceTool {
            // Came from a tool: go back there; after a real clean the tool re-runs.
            toolRequests = nil
            cleanSourceTool = nil
            if realRun { toolsNeedRefresh.insert(tool) }
            withAnimation(Theme.Motion.spring) {
                stage = lastResult == nil ? .dashboard : .results
                section = .tools
            }
            return
        }
        if realRun { lastResult = nil; selection = [:] }
        withAnimation(Theme.Motion.spring) { stage = .dashboard }
    }

    // MARK: Dashboard data

    /// Bytes found per category in the last scan.
    public func bytes(category: RuleCategory) -> Int64? {
        guard let result = lastResult else { return nil }
        return result.results.filter { $0.rule.category == category }.reduce(0) { $0 + $1.bytes }
    }
}

// MARK: - Helpers

/// Forwards Cleaner progress (any thread) to the main actor.
private final class ProgressSink: Sendable {
    private let handler: @MainActor @Sendable (CleanEntry) -> Void
    init(_ handler: @escaping @MainActor @Sendable (CleanEntry) -> Void) { self.handler = handler }
    func send(_ entry: CleanEntry) {
        let handler = handler
        Task { @MainActor in handler(entry) }
    }
}

/// Bytes → number + unit for dot-matrix display (decimal units, like Finder).
public struct ByteDisplay: Equatable, Sendable {
    public var value: Double
    public var decimals: Int
    public var unit: String

    public init(_ bytes: Int64) {
        let b = Double(max(0, bytes))
        switch b {
        case 1e12...:
            value = b / 1e12; unit = "ТБ"; decimals = value < 10 ? 1 : 0
        case 1e9...:
            value = b / 1e9; unit = "ГБ"; decimals = value < 10 ? 1 : 0
        case 1e6...:
            value = b / 1e6; unit = "МБ"; decimals = 0
        default:
            value = b / 1e3; unit = "КБ"; decimals = 0
        }
    }

    /// Fixed unit (used to keep a counter stable while it grows).
    public init(_ bytes: Int64, gigabytes decimals: Int) {
        value = Double(max(0, bytes)) / 1e9
        unit = "ГБ"
        self.decimals = decimals
    }

    public var text: String { DotMatrixNumber.format(value, decimals: decimals) + " " + unit }
}

/// «1 объект», «3 объекта», «5 объектов».
public func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    let word = (m10 == 1 && m100 != 11) ? one : ((2...4).contains(m10) && !(12...14).contains(m100)) ? few : many
    return "\(n) \(word)"
}

public func shortBytes(_ bytes: Int64) -> String { ByteDisplay(bytes).text }

public extension Tier {
    var badge: TierBadge.Kind {
        switch self {
        case .green: .safe
        case .yellow: .review
        case .red: .personal
        }
    }
}

public extension RuleCategory {
    var title: String {
        switch self {
        case .system: "Система"
        case .creative: "Творческие программы"
        case .dev: "Разработка"
        case .ai: "AI и модели"
        case .personal: "Личное"
        }
    }

    var shortTitle: String {
        switch self {
        case .system: "Система"
        case .creative: "Творчество"
        case .dev: "Разработка"
        case .ai: "AI-модели"
        case .personal: "Личное"
        }
    }

    var subtitle: String {
        switch self {
        case .system: "Кэши / Логи / Браузеры"
        case .creative: "Adobe / Blender / DaVinci"
        case .dev: "Xcode / Симуляторы / Пакеты"
        case .ai: "Hugging Face / Ollama / LM Studio"
        case .personal: "Загрузки / Корзина"
        }
    }

    var palette: Palette {
        switch self {
        case .system: .system
        case .creative: .adobe
        case .dev: .xcode
        case .ai: .ai
        case .personal: .downloads
        }
    }

    var systemImage: String {
        switch self {
        case .system: "gearshape.fill"
        case .creative: "film.stack"
        case .dev: "hammer.fill"
        case .ai: "brain.head.profile"
        case .personal: "person.crop.circle"
        }
    }
}

public extension Rule {
    var paletteKey: Palette { Palette(rawValue: palette) ?? category.palette }
}

/// Human names for running apps that block a rule ("Закрой After Effects…").
@MainActor
public func appNames(for bundleIDs: [String]) -> [String] {
    var names: [String] = []
    for id in bundleIDs {
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent
            ?? id
        if !names.contains(name) { names.append(name) }
    }
    return names
}
