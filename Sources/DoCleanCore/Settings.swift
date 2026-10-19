import Foundation
import Observation

/// User settings. Persisted as JSON in `~/Library/Application Support/do clean/settings.json`.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Folders (or files) that are never scanned or cleaned. `~` allowed.
    public var excludedPaths: [String] = []
    /// Rules the user switched off for good.
    public var excludedRuleIDs: [String] = []
    /// Remind to clean every N days; 0 = never.
    public var reminderDays: Int = 7
    /// Threshold of the "Large files" tool, in bytes.
    public var largeFileThreshold: Int64 = LargeFilesFinder.defaultThreshold
    /// How the GREEN tier is removed: permanently, or via the Trash. Yellow/red always use the Trash.
    public var greenMethod: DeletionMethod = .delete
    public var language: Language = .ru
    /// Structurize presets saved by the user.
    public var structurePresets: [StructurePreset] = []
    /// Set once on first launch (the reminder counts from here until the first cleanup).
    public var firstLaunchAt: Date?
    /// When the last reminder was shown.
    public var lastReminderAt: Date?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case excludedPaths, excludedRuleIDs, reminderDays, largeFileThreshold, greenMethod, language, firstLaunchAt, lastReminderAt, structurePresets
    }

    /// Tolerant decoding: missing or unknown values fall back to defaults, so a settings file from another version never breaks launch.
    public init(from d: Decoder) throws {
        self.init()
        let c = try d.container(keyedBy: CodingKeys.self)
        excludedPaths = (try? c.decode([String].self, forKey: .excludedPaths)) ?? excludedPaths
        excludedRuleIDs = (try? c.decode([String].self, forKey: .excludedRuleIDs)) ?? excludedRuleIDs
        reminderDays = max(0, (try? c.decode(Int.self, forKey: .reminderDays)) ?? reminderDays)
        largeFileThreshold = max(1_000_000, (try? c.decode(Int64.self, forKey: .largeFileThreshold)) ?? largeFileThreshold)
        let method = (try? c.decode(DeletionMethod.self, forKey: .greenMethod)) ?? greenMethod
        greenMethod = method == .trash ? .trash : .delete
        language = (try? c.decode(Language.self, forKey: .language)) ?? language
        structurePresets = (try? c.decode([StructurePreset].self, forKey: .structurePresets)) ?? []
        firstLaunchAt = try? c.decode(Date.self, forKey: .firstLaunchAt)
        lastReminderAt = try? c.decode(Date.self, forKey: .lastReminderAt)
    }

    /// Built-in presets followed by the user's.
    public func allStructurePresets() -> [StructurePreset] { StructurePreset.builtIn(language: language) + structurePresets }

    public func exclusions(home: URL) -> Exclusions {
        Exclusions(paths: excludedPaths.map { p in
            (p == "~" || p.hasPrefix("~/")) ? home.path + p.dropFirst(1) : p
        }, ruleIDs: Set(excludedRuleIDs))
    }
}

public extension DoCleanEnvironment {
    /// Same environment with the user's exclusions applied (Scanner, tools and Cleaner all enforce them).
    func applying(_ settings: AppSettings) -> DoCleanEnvironment {
        var e = self
        e.exclusions = settings.exclusions(home: home)
        return e
    }
}

public extension Cleaner {
    /// Cleaner honouring `greenMethod`.
    init(environment: DoCleanEnvironment, settings: AppSettings, trasher: any Trasher = FileManagerTrasher(), history: History? = nil) {
        self.init(environment: environment.applying(settings), trasher: trasher, history: history, greenMethod: settings.greenMethod)
    }
}

public extension LargeFilesFinder {
    init(environment: DoCleanEnvironment, settings: AppSettings, limit: Int = 500, dates: any FileDateProvider = SpotlightFileDates()) {
        self.init(environment: environment.applying(settings), minBytes: settings.largeFileThreshold, limit: limit, dates: dates)
    }
}

/// Reads and writes the settings file. Thread-safe.
public final class SettingsStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/do clean/settings.json")
    }

    /// Missing or corrupt file = defaults.
    public func load() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return AppSettings() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func save(_ s: AppSettings) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: fileURL, options: .atomic)
    }
}

/// Observable settings for SwiftUI: edit `settings`, it is saved on every change.
@MainActor @Observable
public final class SettingsModel {
    public var settings: AppSettings { didSet { if settings != oldValue { try? store.save(settings) } } }
    @ObservationIgnored private let store: SettingsStore

    public init(store: SettingsStore, now: Date = Date()) {
        self.store = store
        var s = store.load()
        if s.firstLaunchAt == nil { s.firstLaunchAt = now; try? store.save(s) }
        settings = s
    }

    public func exclude(path: String) { if !settings.excludedPaths.contains(path) { settings.excludedPaths.append(path) } }
    public func include(path: String) { settings.excludedPaths.removeAll { $0 == path } }
    public func setRule(_ id: String, excluded: Bool) {
        settings.excludedRuleIDs.removeAll { $0 == id }
        if excluded { settings.excludedRuleIDs.append(id) }
    }
}

// MARK: - Exclusions

/// Paths and rules the user excluded. Enforced in the scanner, the tools and (again) in the cleaner.
public struct Exclusions: Sendable, Equatable {
    public static let none = Exclusions()
    public var paths: [String]
    public var ruleIDs: Set<String>

    public init(paths: [String] = [], ruleIDs: Set<String> = []) {
        // Keep both the spelling the user gave and the symlink-resolved one.
        var all: [String] = []
        for p in paths where !p.isEmpty {
            let url = URL(fileURLWithPath: p)
            for v in [url.standardizedFileURL.path, SafetyGuard.canonical(url)] where !all.contains(v) { all.append(v) }
        }
        self.paths = all; self.ruleIDs = ruleIDs
    }

    public var isEmpty: Bool { paths.isEmpty && ruleIDs.isEmpty }
    public func excludes(rule id: String) -> Bool { ruleIDs.contains(id) }

    /// `path` lies inside an excluded folder (or is it).
    public func covers(_ path: String) -> Bool { paths.contains { SafetyGuard.isInside(path, of: $0) } }

    /// Excluded stuff lies at or inside `path`: removing `path` would take it along.
    public func containsExcluded(in path: String) -> Bool { paths.contains { SafetyGuard.isInside($0, of: path) } }

    /// Never touch this item.
    public func blocks(_ url: URL) -> Bool {
        if paths.isEmpty { return false }
        let lexical = url.standardizedFileURL.path
        if covers(lexical) || containsExcluded(in: lexical) { return true }
        let real = SafetyGuard.canonical(url)
        return real != lexical && (covers(real) || containsExcluded(in: real))
    }
}
