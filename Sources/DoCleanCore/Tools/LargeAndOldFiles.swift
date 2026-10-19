import Foundation

private let largeTitle = L10n(ru: "Большие файлы", en: "Large files")
private let oldTitle = L10n(ru: "Старые файлы", en: "Old files")

/// Big files anywhere in the home folder (Documents, Desktop, Pictures and Movies included — preview + Trash only).
public struct LargeFilesFinder: Sendable {
    public static let defaultThreshold: Int64 = 500 * 1_000_000
    public var environment: DoCleanEnvironment
    public var minBytes: Int64
    public var limit: Int
    public var dates: any FileDateProvider

    public init(environment: DoCleanEnvironment, minBytes: Int64 = LargeFilesFinder.defaultThreshold, limit: Int = 500,
                dates: any FileDateProvider = SpotlightFileDates()) {
        self.environment = environment; self.minBytes = minBytes; self.limit = limit; self.dates = dates
    }

    /// Biggest first. Cancel by cancelling the Task.
    public func find(progress: ToolProgressHandler? = nil) async -> [ToolFile] {
        var entries: [HomeWalker.Entry] = []
        HomeWalker.walk(home: environment.home, minAllocated: minBytes, exclusions: environment.exclusions, progress: progress, phase: "scan") { entries.append($0) }
        if Task.isCancelled { return [] }
        let guardrail = environment.guardrail.relaxedForTools()
        return entries.sorted { $0.allocated > $1.allocated }
            .filter { (try? guardrail.checkPath($0.url)) != nil }
            .prefix(limit).map { HomeWalker.toolFile($0, dates: dates) }
    }

    public func cleanRequest(_ files: [ToolFile]) -> CleanRequest { ToolCleanup.request(id: "tool-large-files", title: largeTitle, files: files) }
}

/// Files not opened for a long time.
public struct OldFilesFinder: Sendable {
    public var environment: DoCleanEnvironment
    public var minBytes: Int64
    public var olderThanDays: Int
    public var dates: any FileDateProvider

    public init(environment: DoCleanEnvironment, minBytes: Int64 = 50 * 1_000_000, olderThanDays: Int = 365,
                dates: any FileDateProvider = SpotlightFileDates()) {
        self.environment = environment; self.minBytes = minBytes; self.olderThanDays = olderThanDays; self.dates = dates
    }

    /// Oldest first. "Old" = not opened or modified for `olderThanDays` (date added is ignored).
    public func find(progress: ToolProgressHandler? = nil) async -> [ToolFile] {
        var entries: [HomeWalker.Entry] = []
        HomeWalker.walk(home: environment.home, minAllocated: minBytes, exclusions: environment.exclusions, progress: progress, phase: "scan") { entries.append($0) }
        if Task.isCancelled { return [] }
        let limit = environment.now().addingTimeInterval(-Double(olderThanDays) * 86_400)
        let guardrail = environment.guardrail.relaxedForTools()
        let files = entries.filter { ($0.modified ?? .distantFuture) < limit && (try? guardrail.checkPath($0.url)) != nil }
            .map { HomeWalker.toolFile($0, dates: dates) }
            .filter { ($0.lastUsedOrModified ?? .distantFuture) < limit }
        return files.sorted { ($0.lastUsedOrModified ?? .distantPast) < ($1.lastUsedOrModified ?? .distantPast) }
    }

    public func cleanRequest(_ files: [ToolFile]) -> CleanRequest { ToolCleanup.request(id: "tool-old-files", title: oldTitle, files: files) }
}
