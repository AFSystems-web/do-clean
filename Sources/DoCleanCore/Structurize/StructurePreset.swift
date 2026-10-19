import Foundation
import UniformTypeIdentifiers

/// "extension / mask / type → folder". Rules are tried in order; the first enabled match wins.
public struct StructureRule: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// Extensions without the dot, case-insensitive.
    public var extensions: [String]
    /// fnmatch masks on the file name, case-insensitive ("Screenshot*").
    public var globs: [String]
    /// UTType identifiers the file must conform to ("public.movie").
    public var utTypes: [String]
    /// Relative target folder, may be nested ("Фото/Скриншоты") and may use `{year}`, `{month}`, `{monthName}`.
    public var target: String
    /// Optional age conditions on the modification date.
    public var olderThanDays: Int?
    public var newerThanDays: Int?
    /// Matches every file (still subject to the conditions above).
    public var matchesAll: Bool

    public init(id: String = UUID().uuidString, name: String, enabled: Bool = true, extensions: [String] = [], globs: [String] = [],
                utTypes: [String] = [], target: String, olderThanDays: Int? = nil, newerThanDays: Int? = nil, matchesAll: Bool = false) {
        self.id = id; self.name = name; self.enabled = enabled; self.extensions = extensions; self.globs = globs
        self.utTypes = utTypes; self.target = target; self.olderThanDays = olderThanDays; self.newerThanDays = newerThanDays
        self.matchesAll = matchesAll
    }

    func matches(name fileName: String, modified: Date?, now: Date) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        var typeMatch = matchesAll
        if !typeMatch, !ext.isEmpty, extensions.contains(where: { $0.lowercased() == ext }) { typeMatch = true }
        if !typeMatch, globs.contains(where: { fnmatch($0.lowercased(), fileName.lowercased(), 0) == 0 }) { typeMatch = true }
        if !typeMatch, !ext.isEmpty, !utTypes.isEmpty, let t = UTType(filenameExtension: ext),
           utTypes.contains(where: { UTType($0).map { t.conforms(to: $0) } ?? false }) { typeMatch = true }
        guard typeMatch else { return false }
        let age = modified.map { now.timeIntervalSince($0) / 86_400 }
        if let o = olderThanDays { guard let age, age >= Double(o) else { return false } }
        if let n = newerThanDays { guard let age, age < Double(n) else { return false } }
        return true
    }
}

/// Folder names used by the "Creative" strategy.
public struct ProjectLayout: Codable, Hashable, Sendable {
    public var root: String
    public var sources: String
    public var renders: String
    public var edit: String
    public var audio: String
    public var exports: String
    public init(root: String, sources: String, renders: String, edit: String, audio: String, exports: String) {
        self.root = root; self.sources = sources; self.renders = renders; self.edit = edit; self.audio = audio; self.exports = exports
    }
}

public enum StructureStrategy: String, Codable, Sendable {
    /// Plain "rules → folder".
    case rules
    /// Group loose files into projects by common name prefix; project folders move whole into `projectLayout.root`.
    case creative
}

public struct StructurePreset: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: L10n
    public var subtitle: L10n
    public var strategy: StructureStrategy
    public var rules: [StructureRule]
    /// Folders created (empty) even if nothing lands in them, e.g. "В работе".
    public var folders: [String]
    public var projectLayout: ProjectLayout?
    public var isBuiltIn: Bool

    public init(id: String, title: L10n, subtitle: L10n = L10n(ru: "", en: ""), strategy: StructureStrategy = .rules,
                rules: [StructureRule] = [], folders: [String] = [], projectLayout: ProjectLayout? = nil, isBuiltIn: Bool = false) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.strategy = strategy; self.rules = rules
        self.folders = folders; self.projectLayout = projectLayout; self.isBuiltIn = isBuiltIn
    }

    /// A user copy of a built-in preset, ready to be edited and saved in Settings.
    public func duplicated(as newID: String = UUID().uuidString, title: L10n? = nil) -> StructurePreset {
        var p = self; p.id = newID; p.isBuiltIn = false
        if let title { p.title = title } else { p.title = L10n(ru: self.title.ru + " (копия)", en: self.title.en + " (copy)") }
        return p
    }
}
