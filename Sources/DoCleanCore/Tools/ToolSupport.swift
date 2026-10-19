import Foundation
import CoreServices
import Observation

/// A file found by one of the tools.
public struct ToolFile: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    /// Real allocated size on disk.
    public var bytes: Int64
    public var modified: Date?
    public var lastOpened: Date?
    public var dateAdded: Date?
    public var url: URL { URL(fileURLWithPath: path) }

    public init(path: String, name: String, bytes: Int64, modified: Date? = nil, lastOpened: Date? = nil, dateAdded: Date? = nil) {
        self.path = path; self.name = name; self.bytes = bytes; self.modified = modified; self.lastOpened = lastOpened; self.dateAdded = dateAdded
    }

    /// Most recent sign of life (opened, added or modified). Used for every "older than" decision, so the tools err on the safe side.
    public var lastTouched: Date? { [modified, lastOpened, dateAdded].compactMap { $0 }.max() }

    /// Last time the user opened or changed it; date added is ignored (restores/migrations reset it).
    public var lastUsedOrModified: Date? { [modified, lastOpened].compactMap { $0 }.max() }

    /// Input for `Cleaner`.
    public var scanItem: ScanItem {
        ScanItem(id: path, name: name, path: path, bytes: bytes, fingerprint: modified, lastUsed: lastOpened ?? modified)
    }
}

public struct ToolProgress: Sendable {
    public var filesVisited: Int
    public var bytesFound: Int64
    public var phase: String
    public var currentPath: String?
    public init(filesVisited: Int, bytesFound: Int64, phase: String, currentPath: String? = nil) {
        self.filesVisited = filesVisited; self.bytesFound = bytesFound; self.phase = phase; self.currentPath = currentPath
    }
}
public typealias ToolProgressHandler = @Sendable (ToolProgress) -> Void

/// Where "last opened" / "date added" come from. Spotlight in the app, scripted in tests.
public protocol FileDateProvider: Sendable {
    func lastOpened(_ url: URL) -> Date?
    func dateAdded(_ url: URL) -> Date?
}

public struct SpotlightFileDates: FileDateProvider {
    public init() {}
    private func attr(_ url: URL, _ key: CFString) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, key) as? Date
    }
    public func lastOpened(_ url: URL) -> Date? { attr(url, kMDItemLastUsedDate) }
    public func dateAdded(_ url: URL) -> Date? { attr(url, kMDItemDateAdded) }
}

/// Knows nothing: everything falls back to the modification date.
public struct NoFileDates: FileDateProvider {
    public init() {}
    public func lastOpened(_ url: URL) -> Date? { nil }
    public func dateAdded(_ url: URL) -> Date? { nil }
}

/// Builds Cleaner requests for tool results. Always Trash, Documents/Desktop/Pictures allowed (preview + Trash only).
public enum ToolCleanup {
    public static func rule(id: String, title: L10n, roots: [String] = ["~"]) -> Rule {
        Rule(id: id, title: title, whySafe: L10n(ru: "Файлы уходят в Корзину, откуда их можно вернуть.", en: "Files go to the Trash, where you can restore them."),
             tier: .red, category: .personal, palette: "downloads", deletion: .trash, roots: roots, itemMode: .files)
    }
    public static func request(id: String, title: L10n, files: [ToolFile]) -> CleanRequest {
        CleanRequest(rule: rule(id: id, title: title), items: files.map(\.scanItem), allowUserFolders: true)
    }
}

/// Recursive walk of the home folder shared by the large / old / duplicate tools.
enum HomeWalker {
    static let skipTopLevel: Set<String> = ["Library", "Applications", "Music", "Public"]
    static let skipNames: Set<String> = ["node_modules", ".git"]
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey,
        .ubiquitousItemDownloadingStatusKey,
    ]

    struct Entry { var url: URL; var allocated: Int64; var logical: Int64; var modified: Date?; var identifier: String? }

    /// Calls `visit` for each regular, locally present file with `allocated >= minAllocated`.
    /// Skips hidden items, symlinks, packages (Photos libraries, .app, …), the Library, and iCloud placeholders.
    static func walk(home: URL, minAllocated: Int64, exclusions: Exclusions = .none, progress: ToolProgressHandler? = nil, phase: String,
                     visit: (Entry) -> Void) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: home, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                                     errorHandler: { _, _ in true }) else { return }
        var visited = 0
        var found: Int64 = 0
        let homePath = home.path
        for case let url as URL in en {
            if Task.isCancelled { return }
            let name = url.lastPathComponent
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { en.skipDescendants(); continue }
            if !exclusions.isEmpty, exclusions.covers(url.standardizedFileURL.path) { if v.isDirectory == true { en.skipDescendants() }; continue }
            if v.isDirectory == true {
                let parentIsHome = url.deletingLastPathComponent().path == homePath
                if v.isPackage == true || skipNames.contains(name) || (parentIsHome && skipTopLevel.contains(name)) {
                    en.skipDescendants()
                }
                continue
            }
            guard v.isRegularFile == true else { continue }
            visited += 1
            if let st = v.ubiquitousItemDownloadingStatus, st == URLUbiquitousItemDownloadingStatus.notDownloaded { continue }
            let allocated = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            let logical = Int64(v.fileSize ?? 0)
            if allocated > 0, allocated >= minAllocated {
                found += allocated
                var st = stat()
                let id = lstat(url.path, &st) == 0 ? "\(st.st_dev):\(st.st_ino)" : nil
                visit(Entry(url: url, allocated: allocated, logical: logical, modified: v.contentModificationDate, identifier: id))
            }
            if visited % 2000 == 0 { progress?(ToolProgress(filesVisited: visited, bytesFound: found, phase: phase, currentPath: url.path)) }
        }
        progress?(ToolProgress(filesVisited: visited, bytesFound: found, phase: phase, currentPath: nil))
    }

    static func toolFile(_ e: Entry, dates: any FileDateProvider) -> ToolFile {
        ToolFile(path: e.url.path, name: e.url.lastPathComponent, bytes: e.allocated, modified: e.modified,
                 lastOpened: dates.lastOpened(e.url), dateAdded: dates.dateAdded(e.url))
    }
}

/// Generic observable runner so a UI can bind to any tool: progress + result.
@MainActor @Observable
public final class ToolModel<Output: Sendable> {
    public enum Phase: Sendable { case idle, running, done, cancelled }
    public private(set) var phase: Phase = .idle
    public private(set) var progress = ToolProgress(filesVisited: 0, bytesFound: 0, phase: "", currentPath: nil)
    public private(set) var output: Output?
    private var task: Task<Void, Never>?
    public init() {}

    /// `operation` receives a progress handler and should honour task cancellation.
    public func run(_ operation: @escaping @Sendable (@escaping ToolProgressHandler) async -> Output) {
        cancel()
        phase = .running; output = nil
        task = Task { [weak self] in
            let result = await operation { p in Task { @MainActor in self?.progress = p } }
            guard let self, !Task.isCancelled else { return }
            self.output = result; self.phase = .done
        }
    }
    public func cancel() { task?.cancel(); task = nil; if phase == .running { phase = .cancelled } }
}
