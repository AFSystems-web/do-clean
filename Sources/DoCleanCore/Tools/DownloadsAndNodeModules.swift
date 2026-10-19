import Foundation

public enum DownloadsFilter: Sendable, Equatable {
    case olderThan(days: Int)
    case installers
    case all
}

public struct DownloadItem: Identifiable, Sendable {
    public var id: String { file.path }
    public var file: ToolFile
    public var isInstaller: Bool
    public var isDirectory: Bool
    /// Age reference: the latest of date added / last opened (falls back to modified).
    public var reference: Date? { file.lastTouched }
}

public struct DownloadsTool: Sendable {
    public var environment: DoCleanEnvironment
    public var dates: any FileDateProvider
    public init(environment: DoCleanEnvironment, dates: any FileDateProvider = SpotlightFileDates()) {
        self.environment = environment; self.dates = dates
    }

    var root: URL { environment.home.appendingPathComponent("Downloads", isDirectory: true) }

    /// Every top-level entry of ~/Downloads, newest first. Filter with `apply`.
    public func list() async -> [DownloadItem] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [DownloadItem] = []
        for url in children where !CleanScanner.ignoredNames.contains(url.lastPathComponent) && !environment.exclusions.blocks(url) {
            if Task.isCancelled { return [] }
            let m = FileMeasure.measure(url)
            let isDir = CleanScanner.isDirectory(url)
            // Folder "modified" must be the folder's own date for age purposes; fingerprint uses the newest inside.
            let own = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let file = ToolFile(path: url.path, name: url.lastPathComponent, bytes: m.bytes, modified: isDir ? (m.newest ?? own) : own,
                                lastOpened: dates.lastOpened(url), dateAdded: dates.dateAdded(url))
            out.append(DownloadItem(file: file, isInstaller: Self.isInstaller(url, isDirectory: isDir), isDirectory: isDir))
        }
        return out.sorted { ($0.reference ?? .distantPast) > ($1.reference ?? .distantPast) }
    }

    public func apply(_ filter: DownloadsFilter, to items: [DownloadItem]) -> [DownloadItem] {
        switch filter {
        case .all: return items
        case .installers: return items.filter(\.isInstaller)
        case .olderThan(let days):
            let limit = environment.now().addingTimeInterval(-Double(days) * 86_400)
            return items.filter { ($0.reference ?? .distantFuture) < limit }
        }
    }

    public func find(_ filter: DownloadsFilter) async -> [DownloadItem] { apply(filter, to: await list()) }

    public func cleanRequest(_ items: [DownloadItem]) -> CleanRequest {
        let rule = Rule(id: "tool-downloads", title: L10n(ru: "Загрузки", en: "Downloads"),
                        whySafe: L10n(ru: "Файлы уходят в Корзину, откуда их можно вернуть.", en: "Files go to the Trash, where you can restore them."),
                        tier: .red, category: .personal, palette: "downloads", deletion: .trash, roots: ["~/Downloads"])
        return CleanRequest(rule: rule, items: items.map(\.file.scanItem))
    }

    /// .dmg/.pkg/.mpkg/.iso always; .zip when it contains an .app or its name looks like an installer.
    static func isInstaller(_ url: URL, isDirectory: Bool) -> Bool {
        if isDirectory { return false }
        let ext = url.pathExtension.lowercased()
        if ["dmg", "pkg", "mpkg", "iso"].contains(ext) { return true }
        guard ext == "zip" else { return false }
        let n = url.deletingPathExtension().lastPathComponent.lowercased()
        if ["install", "setup", "installer", "macos", "osx", "arm64", "universal", "apple-silicon", "x86_64", "intel"].contains(where: { n.contains($0) }) { return true }
        return zipContainsApp(url)
    }

    /// Scans the end of the zip (central directory lists file names in plain text) for ".app/".
    static func zipContainsApp(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size > 0 else { return false }
        let window = min(size, 1 << 20)
        guard (try? h.seek(toOffset: size - window)) != nil, let data = try? h.read(upToCount: Int(window)) else { return false }
        return data.range(of: Data(".app/".utf8)) != nil
    }
}

public struct NodeModulesProject: Identifiable, Sendable {
    public var id: String { item.id }
    public var name: String
    public var projectPath: String
    public var item: ScanItem
    public var bytes: Int64 { item.bytes }
    /// Last activity in the project (source files / git), not the install date.
    public var projectLastModified: Date? { item.lastUsed }
}

/// Wraps the `node-modules` catalog rule with a configurable age (0 = every project).
public struct NodeModulesFinder: Sendable {
    public var environment: DoCleanEnvironment
    public var olderThanDays: Int
    public init(environment: DoCleanEnvironment, olderThanDays: Int = 30) {
        self.environment = environment; self.olderThanDays = olderThanDays
    }

    public var rule: Rule? {
        guard var r = try? RuleCatalog.load().first(where: { $0.id == "node-modules" }) else { return nil }
        r.minAgeDays = olderThanDays
        return r
    }

    /// Biggest first.
    public func find() async -> (projects: [NodeModulesProject], request: CleanRequest)? {
        guard let rule else { return nil }
        let res = await CleanScanner(environment: environment).scan(rule: rule)
        let projects = res.items.map { item -> NodeModulesProject in
            let project = item.url?.deletingLastPathComponent()
            return NodeModulesProject(name: project?.lastPathComponent ?? item.name, projectPath: project?.path ?? "", item: item)
        }
        return (projects, CleanRequest(rule: rule, items: res.items))
    }
}
