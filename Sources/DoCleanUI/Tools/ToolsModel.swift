import SwiftUI
import DoCleanCore

/// The five tools of the «Инструменты» tab.
public enum ToolKind: String, CaseIterable, Sendable, Identifiable {
    case large, duplicates, downloads, nodeModules, old

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .large: "Большие файлы"
        case .duplicates: "Дубликаты"
        case .downloads: "Загрузки"
        case .nodeModules: "node_modules"
        case .old: "Старые файлы"
        }
    }

    public var subtitle: String {
        switch self {
        case .large: "Самые тяжёлые файлы в домашней папке"
        case .duplicates: "Одинаковые файлы: одну копию оставляем"
        case .downloads: "Что лежит в Загрузках и давно не открывалось"
        case .nodeModules: "Зависимости проектов, которые давно не трогали"
        case .old: "Большие файлы, которые год не открывали"
        }
    }

    public var systemImage: String {
        switch self {
        case .large: "externaldrive.fill"
        case .duplicates: "square.on.square"
        case .downloads: "arrow.down.circle.fill"
        case .nodeModules: "shippingbox.fill"
        case .old: "hourglass"
        }
    }

    public var palette: Palette {
        switch self {
        case .large: .adobe
        case .duplicates: .ai
        case .downloads: .downloads
        case .nodeModules: .xcode
        case .old: .personal
        }
    }
}

/// Small observable runner: phase, live progress, output, cancel.
@MainActor @Observable
public final class ToolRun<Output: Sendable> {
    public enum Phase: Sendable, Equatable { case idle, running, done, cancelled }
    public private(set) var phase: Phase = .idle
    public private(set) var progress: ToolProgress?
    public private(set) var output: Output?
    public private(set) var startedAt: Date?
    private var task: Task<Void, Never>?

    public init() {}

    public var isRunning: Bool { phase == .running }

    public func run(_ operation: @escaping @Sendable (@escaping ToolProgressHandler) async -> Output,
                    then done: @escaping @MainActor (Output) -> Void = { _ in }) {
        cancel()
        phase = .running
        startedAt = Date()
        progress = nil
        let sink = ToolProgressSink { [weak self] p in self?.progress = p }
        task = Task { [weak self] in
            let result = await operation { p in sink.send(p) }
            guard let self, !Task.isCancelled else { return }
            self.output = result
            self.phase = .done
            done(result)
        }
    }

    /// Installs a result directly (tests, snapshots).
    public func set(_ output: Output) {
        self.output = output
        phase = .done
    }

    public func cancel() {
        task?.cancel()
        task = nil
        if phase == .running { phase = output == nil ? .cancelled : .done }
    }
}

private final class ToolProgressSink: Sendable {
    private let handler: @MainActor @Sendable (ToolProgress) -> Void
    init(_ handler: @escaping @MainActor @Sendable (ToolProgress) -> Void) { self.handler = handler }
    func send(_ p: ToolProgress) {
        let handler = handler
        Task { @MainActor in handler(p) }
    }
}

public struct NodeModulesOutput: Sendable {
    public var projects: [NodeModulesProject]
    public var request: CleanRequest?
}

/// State of the tools tab: one runner + selection per tool.
@MainActor @Observable
public final class ToolsModel {
    public let baseEnvironment: DoCleanEnvironment
    /// Exclusions from Settings, applied to every walk.
    public var exclusionsProvider: @MainActor () -> AppSettings? = { nil }
    public var environment: DoCleanEnvironment {
        exclusionsProvider().map { baseEnvironment.applying($0) } ?? baseEnvironment
    }
    public var dates: any FileDateProvider
    public var current: ToolKind = .large

    // Large files
    public var largeMinMB: Int = 500
    public let large = ToolRun<[ToolFile]>()
    public var largeSelection: Set<String> = []

    // Old files
    public var oldDays: Int = 365
    public let old = ToolRun<[ToolFile]>()
    public var oldSelection: Set<String> = []

    // Duplicates
    public let duplicates = ToolRun<[DuplicateGroup]>()
    /// group id → path to keep.
    public var keep: [String: String] = [:]
    public var duplicateSelection: Set<String> = []

    // Downloads
    public var downloadsFilter: DownloadsFilter = .olderThan(days: 90)
    public let downloads = ToolRun<[DownloadItem]>()
    public var downloadsSelection: Set<String> = []

    // node_modules
    public var nodeDays: Int = 30
    public let nodeModules = ToolRun<NodeModulesOutput>()
    public var nodeSelection: Set<String> = []

    public init(environment: DoCleanEnvironment, dates: any FileDateProvider = SpotlightFileDates()) {
        self.baseEnvironment = environment
        self.dates = dates
    }

    // MARK: Running

    public func isRunning(_ kind: ToolKind) -> Bool {
        switch kind {
        case .large: large.isRunning
        case .duplicates: duplicates.isRunning
        case .downloads: downloads.isRunning
        case .nodeModules: nodeModules.isRunning
        case .old: old.isRunning
        }
    }

    public func hasOutput(_ kind: ToolKind) -> Bool {
        switch kind {
        case .large: large.output != nil
        case .duplicates: duplicates.output != nil
        case .downloads: downloads.output != nil
        case .nodeModules: nodeModules.output != nil
        case .old: old.output != nil
        }
    }

    public func progress(_ kind: ToolKind) -> ToolProgress? {
        switch kind {
        case .large: large.progress
        case .duplicates: duplicates.progress
        case .downloads: downloads.progress
        case .nodeModules: nodeModules.progress
        case .old: old.progress
        }
    }

    public func run(_ kind: ToolKind) {
        let env = environment
        let dates = dates
        switch kind {
        case .large:
            let finder = LargeFilesFinder(environment: env, minBytes: Int64(largeMinMB) * 1_000_000, dates: dates)
            large.run({ p in await finder.find(progress: p) }) { [weak self] _ in self?.largeSelection = [] }
        case .old:
            let finder = OldFilesFinder(environment: env, olderThanDays: oldDays, dates: dates)
            old.run({ p in await finder.find(progress: p) }) { [weak self] _ in self?.oldSelection = [] }
        case .duplicates:
            let finder = DuplicateFinder(environment: env, dates: dates)
            duplicates.run({ p in await finder.find(progress: p) }) { [weak self] groups in self?.resetDuplicates(groups) }
        case .downloads:
            let tool = DownloadsTool(environment: env, dates: dates)
            downloads.run({ _ in await tool.list() }) { [weak self] _ in self?.downloadsSelection = [] }
        case .nodeModules:
            let finder = NodeModulesFinder(environment: env, olderThanDays: nodeDays)
            nodeModules.run({ _ in
                let r = await finder.find()
                return NodeModulesOutput(projects: r?.projects ?? [], request: r?.request)
            }) { [weak self] out in self?.nodeSelection = Set(out.projects.map(\.id)) }
        }
    }

    public func cancel(_ kind: ToolKind) {
        switch kind {
        case .large: large.cancel()
        case .duplicates: duplicates.cancel()
        case .downloads: downloads.cancel()
        case .nodeModules: nodeModules.cancel()
        case .old: old.cancel()
        }
    }

    /// Suggested keep pre-selected; every other copy is selected for the Trash.
    public func resetDuplicates(_ groups: [DuplicateGroup]) {
        keep = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.keep.path) })
        duplicateSelection = Set(groups.flatMap { $0.removable.map(\.path) })
    }

    public func setKeep(_ file: ToolFile, in group: DuplicateGroup) {
        keep[group.id] = file.path
        duplicateSelection.remove(file.path)
        for f in group.files where f.path != file.path { duplicateSelection.insert(f.path) }
    }

    // MARK: Lists

    public var visibleDownloads: [DownloadItem] {
        guard let items = downloads.output else { return [] }
        return DownloadsTool(environment: environment, dates: dates).apply(downloadsFilter, to: items)
            .sorted { $0.file.bytes > $1.file.bytes }
    }

    // MARK: Requests

    public func requests(for kind: ToolKind) -> [CleanRequest] {
        switch kind {
        case .large:
            let files = (large.output ?? []).filter { largeSelection.contains($0.path) }
            return files.isEmpty ? [] : [LargeFilesFinder(environment: environment).cleanRequest(files)]
        case .old:
            let files = (old.output ?? []).filter { oldSelection.contains($0.path) }
            return files.isEmpty ? [] : [OldFilesFinder(environment: environment).cleanRequest(files)]
        case .duplicates:
            return (duplicates.output ?? []).compactMap { g in
                let keepPath = keep[g.id] ?? g.keep.path
                guard let kept = g.files.first(where: { $0.path == keepPath }) else { return nil }
                let remove = g.files.filter { $0.path != keepPath && duplicateSelection.contains($0.path) }
                guard !remove.isEmpty else { return nil }
                return g.cleanRequest(removing: remove, keeping: kept)
            }
        case .downloads:
            let items = visibleDownloads.filter { downloadsSelection.contains($0.id) }
            return items.isEmpty ? [] : [DownloadsTool(environment: environment, dates: dates).cleanRequest(items)]
        case .nodeModules:
            guard let out = nodeModules.output, let req = out.request else { return [] }
            let ids = Set(out.projects.filter { nodeSelection.contains($0.id) }.map(\.item.id))
            let items = req.items.filter { ids.contains($0.id) }
            return items.isEmpty ? [] : [CleanRequest(rule: req.rule, items: items, allowUserFolders: req.allowUserFolders)]
        }
    }

    public func selectedBytes(_ kind: ToolKind) -> Int64 {
        requests(for: kind).reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.bytes } }
    }

    /// Total found (for the tool cards).
    public func foundBytes(_ kind: ToolKind) -> Int64? {
        switch kind {
        case .large: large.output.map { $0.reduce(0) { $0 + $1.bytes } }
        case .old: old.output.map { $0.reduce(0) { $0 + $1.bytes } }
        case .duplicates: duplicates.output.map { $0.reduce(0) { $0 + $1.reclaimableBytes } }
        case .downloads: downloads.output == nil ? nil : visibleDownloads.reduce(0) { $0 + $1.file.bytes }
        case .nodeModules: nodeModules.output.map { $0.projects.reduce(0) { $0 + $1.bytes } }
        }
    }

    public func foundCount(_ kind: ToolKind) -> Int? {
        switch kind {
        case .large: large.output?.count
        case .old: old.output?.count
        case .duplicates: duplicates.output?.count
        case .downloads: downloads.output == nil ? nil : visibleDownloads.count
        case .nodeModules: nodeModules.output?.projects.count
        }
    }
}
