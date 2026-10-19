import Foundation

public enum RuleCatalog {
    public enum CatalogError: Error { case rulesFolderNotFound, duplicateID(String) }

    static let bundleName = "DoClean_DoCleanCore.bundle"

    /// Looks for the resource bundle in the places SwiftPM's generated `Bundle.module`
    /// does NOT check: `do clean.app/Contents/Resources` and next to the executable.
    /// `Bundle.module` itself is only touched as the last resort (it traps when the bundle is missing).
    public static func locateRulesFolder(searchRoots: [URL]? = nil) -> URL? {
        let roots = searchRoots ?? defaultSearchRoots()
        for root in roots {
            let bundleURL = root.appendingPathComponent(bundleName)
            if let b = Bundle(url: bundleURL), let r = b.url(forResource: "Rules", withExtension: nil) { return r }
            // Bundle(url:) can fail for flat layouts; probe the folder directly.
            for sub in ["Contents/Resources/Rules", "Rules"] {
                let direct = bundleURL.appendingPathComponent(sub, isDirectory: true)
                if FileManager.default.fileExists(atPath: direct.path) { return direct }
            }
        }
        guard searchRoots == nil else { return nil }
        return Bundle.module.url(forResource: "Rules", withExtension: nil)
    }

    static func defaultSearchRoots() -> [URL] {
        var r: [URL] = []
        if let u = Bundle.main.resourceURL { r.append(u) }
        r.append(Bundle.main.bundleURL)
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            r.append(exe.deletingLastPathComponent())                                   // swift run / CLI next to bundle
            r.append(exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")) // Contents/MacOS/x -> Contents/Resources
        }
        return r
    }

    /// Loads every `*.json` in the folder (sorted by name), sorted by priority then catalog order.
    public static func load(from folder: URL? = nil) throws -> [Rule] {
        guard let folder = folder ?? locateRulesFolder() else { throw CatalogError.rulesFolderNotFound }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var rules: [Rule] = []
        var seen = Set<String>()
        for f in files {
            let list = try JSONDecoder().decode([Rule].self, from: Data(contentsOf: f))
            for r in list {
                guard seen.insert(r.id).inserted else { throw CatalogError.duplicateID(r.id) }
                rules.append(r)
            }
        }
        return rules.enumerated().sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }.map(\.element)
    }

    /// Personal rules that live only on this Mac: `~/Library/Application Support/do clean/Rules/*.json`.
    /// Same format as the bundled catalog. Every path still goes through SafetyGuard before removal.
    public static func userRulesFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/do clean/Rules", isDirectory: true)
    }

    /// Bundled catalog plus the personal rules (if any). A personal rule cannot replace a bundled id.
    public static func loadWithUserRules(userFolder: URL = userRulesFolder()) throws -> [Rule] {
        let bundled = try load()
        guard FileManager.default.fileExists(atPath: userFolder.path) else { return bundled }
        let personal = try load(from: userFolder)
        let ids = Set(bundled.map(\.id))
        if let clash = personal.first(where: { ids.contains($0.id) }) { throw CatalogError.duplicateID(clash.id) }
        return (bundled + personal).enumerated()
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }.map(\.element)
    }
}
