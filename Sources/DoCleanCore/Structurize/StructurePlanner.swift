import Foundation

public struct PlanOptions: Sendable {
    /// Also look into ordinary sub-folders (project folders are still never entered).
    public var recursive = false
    public var language: Language = .ru
    public init(recursive: Bool = false, language: Language = .ru) { self.recursive = recursive; self.language = language }
}

/// Builds a `MovePlan`. Read-only: nothing on disk changes.
public struct StructurePlanner: Sendable {
    public var environment: DoCleanEnvironment

    public init(environment: DoCleanEnvironment) { self.environment = environment }

    // MARK: protections

    /// A folder holding one of these (within 3 levels) moves as a unit.
    static let unitExtensions: Set<String> = ["prproj", "aep", "aepx", "blend", "xcodeproj", "xcworkspace", "fcpbundle", "fcpxmld", "logicx", "drp", "dra", "als", "flp", "ptx", "cpr", "veg", "kdenlive"]
    static let unitFileNames: Set<String> = ["Package.swift", "package.json", "Cargo.toml", "pom.xml", "go.mod", "pyproject.toml"]
    static let unitDirNames: Set<String> = [".git", ".hg", ".svn"]
    static let bundleExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary",
                                               "xpc", "appex", "prefpane", "saver", "qlgenerator", "mdimporter", "pkg-bundle", "sparsebundle", "xcarchive", "playground", "rtfd", "key-bundle"]
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]

    /// Cheap recursive marker search (depth ≤ 3, ≤ 2000 entries).
    static func isProjectUnit(_ dir: URL) -> Bool {
        var budget = 2000
        func scan(_ d: URL, depth: Int) -> Bool {
            guard let kids = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return false }
            var subdirs: [URL] = []
            for k in kids {
                budget -= 1; if budget < 0 { return false }
                let n = k.lastPathComponent
                if unitDirNames.contains(n) || unitFileNames.contains(n) || unitExtensions.contains(k.pathExtension.lowercased()) { return true }
                if (try? k.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true, !n.hasPrefix("."), n != "node_modules" { subdirs.append(k) }
            }
            guard depth < 3 else { return false }
            return subdirs.contains { scan($0, depth: depth + 1) }
        }
        return scan(dir, depth: 1)
    }

    static func isLooseProjectFile(_ url: URL) -> Bool {
        unitExtensions.contains(url.pathExtension.lowercased()) || unitFileNames.contains(url.lastPathComponent)
    }

    /// Paths of files that processes have open right now (`lsof -F n`), nil when lsof is unavailable.
    func openPaths() -> Set<String>? {
        guard let exe = environment.runner.locate("lsof") else { return nil }
        let out = environment.runner.run(exe, ["-n", "-P", "-F", "n"])
        guard out.status == 0 || !out.stdout.isEmpty else { return nil }
        var set = Set<String>()
        for line in out.stdout.split(separator: "\n") where line.hasPrefix("n/") { set.insert(Self.norm(String(line.dropFirst()))) }
        return set
    }

    static func isBusy(_ path: String, open: Set<String>?, recentlyModified: Bool) -> Bool {
        if recentlyModified { return true }
        guard let open else { return false }
        let path = norm(path)
        if open.contains(path) { return true }
        let prefix = path + "/"
        return open.contains { $0.hasPrefix(prefix) }
    }

    // MARK: planning

    public func plan(sources: [URL], preset: StructurePreset, options: PlanOptions = PlanOptions()) async throws -> MovePlan {
        let guardrail = environment.guardrail.relaxedForTools()
        var moves: [PlannedMove] = []
        var skipped: [SkippedEntry] = []
        var newFolders: [String] = []
        var roots: [String] = []
        let open = openPaths()
        let now = environment.now()

        for source in sources {
            let root = source.standardizedFileURL
            guard FileManager.default.fileExists(atPath: root.path) else { throw StructurizeError.sourceMissing(root.path) }
            do { try guardrail.checkPath(root) } catch { throw StructurizeError.sourceNotAllowed(root.path, "\(error)") }
            if environment.exclusions.covers(root.path) || environment.exclusions.covers(SafetyGuard.canonical(root)) { throw StructurizeError.sourceNotAllowed(root.path, "excluded") }
            // Use the spelling the walker will produce (symlink-resolved), so "inside root" comparisons are consistent.
            let rootPath = Self.realPath(root.path)
            roots.append(rootPath)
            var ctx = Context(root: rootPath, preset: preset, options: options, guardrail: guardrail, open: open, now: now)
            collect(root: URL(fileURLWithPath: rootPath), ctx: &ctx)
            if Task.isCancelled { break }
            let result = decide(&ctx)
            moves += result.moves; skipped += ctx.skipped + result.skipped
            newFolders += result.newFolders
        }
        var seen = Set<String>()
        newFolders = newFolders.filter { seen.insert($0).inserted }.sorted { $0.count < $1.count }
        return MovePlan(presetID: preset.id, presetTitle: preset.title, sources: roots, moves: moves, skipped: skipped, newFolders: newFolders)
    }

    struct Candidate { var url: URL; var isDirectory: Bool; var isUnit: Bool; var bytes: Int64; var modified: Date? }

    struct Context {
        var root: String
        var preset: StructurePreset
        var options: PlanOptions
        var guardrail: SafetyGuard
        var open: Set<String>?
        var now: Date
        var candidates: [Candidate] = []
        var skipped: [SkippedEntry] = []
        func skip(_ url: URL, _ reason: SkipReason, _ detail: String? = nil) -> SkippedEntry {
            SkippedEntry(path: url.path, name: url.lastPathComponent, reason: reason, detail: detail)
        }
    }

    /// Step 1: walk, apply every protection, keep only movable candidates.
    func collect(root: URL, ctx: inout Context) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .contentModificationDateKey,
                                      .ubiquitousItemDownloadingStatusKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        func walk(_ dir: URL, depth: Int) {
            if Task.isCancelled { return }
            guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else { return }
            for url in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.lastPathComponent
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if name.hasPrefix(".") { ctx.skipped.append(ctx.skip(url, .hidden)); continue }
                if v.isSymbolicLink == true { ctx.skipped.append(ctx.skip(url, .symlink)); continue }
                if environment.exclusions.blocks(url) { ctx.skipped.append(ctx.skip(url, .excluded)); continue }
                if (try? ctx.guardrail.checkPath(url)) == nil { ctx.skipped.append(ctx.skip(url, .forbidden)); continue }
                let ext = url.pathExtension.lowercased()
                let recent = (v.contentModificationDate.map { ctx.now.timeIntervalSince($0) } ?? 999) < 60

                if v.isDirectory == true {
                    let isUnitPackage = Self.unitExtensions.contains(ext)           // .fcpbundle, .xcodeproj, .logicx …
                    if !isUnitPackage, v.isPackage == true || Self.bundleExtensions.contains(ext) { ctx.skipped.append(ctx.skip(url, .bundle)); continue }
                    if isUnitPackage || Self.isProjectUnit(url) {
                        if Self.isBusy(url.path, open: ctx.open, recentlyModified: false) { ctx.skipped.append(ctx.skip(url, .busy)); continue }
                        let m = FileMeasure.measure(url)
                        ctx.candidates.append(Candidate(url: url, isDirectory: true, isUnit: true, bytes: m.bytes, modified: v.contentModificationDate))
                    } else if ctx.options.recursive {
                        walk(url, depth: depth + 1)
                    }
                    continue
                }
                if let st = v.ubiquitousItemDownloadingStatus, st == .notDownloaded { ctx.skipped.append(ctx.skip(url, .iCloudPlaceholder)); continue }
                if (v.totalFileAllocatedSize ?? 1) == 0, (v.fileSize ?? 0) > 0 { ctx.skipped.append(ctx.skip(url, .iCloudPlaceholder)); continue }
                if Self.partialExtensions.contains(ext) { ctx.skipped.append(ctx.skip(url, .partialDownload)); continue }
                if Self.bundleExtensions.contains(ext) { ctx.skipped.append(ctx.skip(url, .bundle)); continue }
                if Self.isLooseProjectFile(url) { ctx.skipped.append(ctx.skip(url, .projectFile)); continue }
                if Self.isBusy(url.path, open: ctx.open, recentlyModified: recent) { ctx.skipped.append(ctx.skip(url, .busy)); continue }
                ctx.candidates.append(Candidate(url: url, isDirectory: false, isUnit: false,
                                                bytes: Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0), modified: v.contentModificationDate))
            }
        }
        walk(root, depth: 0)
    }

    // MARK: Step 2 — targets

    func decide(_ ctx: inout Context) -> (moves: [PlannedMove], skipped: [SkippedEntry], newFolders: [String]) {
        var assignments: [(Candidate, String, String)] = []   // candidate, relative target, rule name
        var skipped: [SkippedEntry] = []
        let folders = ctx.preset.folders.compactMap { Self.sanitize($0) }

        switch ctx.preset.strategy {
        case .rules:
            for c in ctx.candidates {
                if c.isUnit { skipped.append(ctx.skip(c.url, .projectUnit, "kept whole")); continue }
                if let r = ctx.preset.rules.first(where: { $0.enabled && $0.matches(name: c.url.lastPathComponent, modified: c.modified, now: ctx.now) }),
                   let target = Self.expand(r.target, date: c.modified ?? ctx.now, language: ctx.options.language) {
                    assignments.append((c, target, r.name))
                } else {
                    skipped.append(ctx.skip(c.url, .noRule))
                }
            }
        case .creative:
            guard let layout = ctx.preset.projectLayout, let projectsRoot = Self.sanitize(layout.root) else { break }
            let loose = ctx.candidates.filter { !$0.isUnit }
            let groups = CreativeGrouping.group(names: loose.map { $0.url.lastPathComponent })
            for c in ctx.candidates {
                if c.isUnit {
                    assignments.append((c, projectsRoot, ctx.options.language == .ru ? "Проект целиком" : "Whole project"))
                } else if let project = groups[c.url.lastPathComponent], let role = CreativeGrouping.role(for: c.url.lastPathComponent, layout: layout),
                          let sub = Self.sanitize(role) {
                    assignments.append((c, "\(projectsRoot)/\(project)/\(sub)", project))
                } else {
                    skipped.append(ctx.skip(c.url, .noRule))
                }
            }
        }

        // Resolve destinations: conflicts get " 2", " 3"… against the disk and against earlier planned moves.
        var taken = Set<String>()
        var moves: [PlannedMove] = []
        var newFolders: [String] = []
        let fm = FileManager.default
        for (c, target, ruleName) in assignments.sorted(by: { $0.0.url.path < $1.0.url.path }) {
            let folder = target.isEmpty ? ctx.root : ctx.root + "/" + target
            // A file in the way of the target folder (or any parent of it) blocks this item.
            if Self.fileBlocksPath(folder, root: ctx.root) { skipped.append(ctx.skip(c.url, .targetBlocked, target)); continue }
            if c.url.deletingLastPathComponent().path == folder { skipped.append(ctx.skip(c.url, .alreadyInPlace)); continue }
            guard Self.isInside(folder, ctx.root) else { skipped.append(ctx.skip(c.url, .outsideSource)); continue }
            let dest = Self.freeName(in: folder, name: c.url.lastPathComponent, isDirectory: c.isDirectory, taken: &taken, fm: fm)
            if (try? ctx.guardrail.checkPath(URL(fileURLWithPath: dest))) == nil { skipped.append(ctx.skip(c.url, .forbidden)); continue }
            moves.append(PlannedMove(source: c.url.path, destination: dest, root: ctx.root, name: c.url.lastPathComponent, isDirectory: c.isDirectory,
                                     isUnit: c.isUnit, bytes: c.bytes, modified: c.modified, ruleName: ruleName))
            Self.collectMissing(folder, root: ctx.root, into: &newFolders, fm: fm)
        }
        for f in folders { Self.collectMissing(ctx.root + "/" + f, root: ctx.root, into: &newFolders, fm: fm) }
        return (moves, skipped, newFolders)
    }

    // MARK: helpers

    /// realpath(3): the spelling the file system itself uses (/private/var/…), which is what directory listings return.
    static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    /// /private/var/x and /var/x are the same place; compare them equal.
    static func norm(_ p: String) -> String { p.hasPrefix("/private/") ? String(p.dropFirst(8)) : p }

    static func isInside(_ p: String, _ root: String) -> Bool { p == root || p.hasPrefix(root + "/") }

    /// Makes a user-provided relative folder safe: no "..", no absolute paths, no empty parts.
    static func sanitize(_ rel: String) -> String? {
        let parts = rel.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." && !$0.isEmpty && !$0.contains("\0") }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    static let monthsRU = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"]
    static let monthsEN = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    static func expand(_ target: String, date: Date, language: Language) -> String? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let c = cal.dateComponents([.year, .month], from: date)
        let m = (c.month ?? 1) - 1
        let t = target.replacingOccurrences(of: "{year}", with: String(c.year ?? 0))
            .replacingOccurrences(of: "{month}", with: String(format: "%02d", m + 1))
            .replacingOccurrences(of: "{monthName}", with: (language == .ru ? monthsRU : monthsEN)[max(0, min(11, m))])
        return sanitize(t)
    }

    static func fileBlocksPath(_ folder: String, root: String) -> Bool {
        var p = folder
        while p.count > root.count {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue { return true }
            p = (p as NSString).deletingLastPathComponent
        }
        return false
    }

    static func collectMissing(_ folder: String, root: String, into list: inout [String], fm: FileManager) {
        var chain: [String] = []
        var p = folder
        while p.count > root.count, !fm.fileExists(atPath: p) { chain.append(p); p = (p as NSString).deletingLastPathComponent }
        list.append(contentsOf: chain.reversed())
    }

    /// "photo.jpg" → "photo 2.jpg" → "photo 3.jpg"; folders: "Project" → "Project 2".
    static func freeName(in folder: String, name: String, isDirectory: Bool, taken: inout Set<String>, fm: FileManager) -> String {
        let ns = name as NSString
        let ext = isDirectory ? "" : ns.pathExtension
        let stem = isDirectory ? name : ns.deletingPathExtension
        var n = 1
        while true {
            let candidateName = n == 1 ? name : (ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            let path = folder + "/" + candidateName
            if !taken.contains(path.lowercased()), !fm.fileExists(atPath: path) {
                taken.insert(path.lowercased())
                return path
            }
            n += 1
        }
    }
}

/// "Creative" strategy: project names from common name prefixes, file roles from type and name hints.
enum CreativeGrouping {
    static let generic: Set<String> = ["img", "dsc", "dscn", "mvi", "vid", "gopr", "dji", "pxl", "screenshot", "screen", "снимок", "photo", "image", "untitled",
                                       "new", "copy", "file", "video", "audio", "scan", "document", "doc", "export", "render", "final", "clip", "track"]
    static let editExt: Set<String> = ["fcpxml", "edl", "aaf", "srt", "xml", "ass", "vtt"]
    static let audioExt: Set<String> = ["mp3", "wav", "aif", "aiff", "flac", "m4a", "aac", "ogg", "opus"]

    static func tokens(_ filename: String) -> [String] {
        let stem = (filename as NSString).deletingPathExtension
        var t = stem.split(whereSeparator: { " _-.".contains($0) }).map(String.init)
        // Trailing counters / versions ("v4", "003", "final") do not belong to the project name.
        while t.count > 1, let last = t.last?.lowercased(), last.allSatisfy(\.isNumber) || last.range(of: #"^v\d+$"#, options: .regularExpression) != nil
                || ["final", "copy", "copy2", "new", "old"].contains(last) { t.removeLast() }
        return t
    }

    /// filename → project name, only for files that share a (non-generic) prefix with at least one other file.
    static func group(names: [String]) -> [String: String] {
        let toks = Dictionary(uniqueKeysWithValues: names.map { ($0, tokens($0)) })
        var count: [String: Int] = [:]
        func keys(_ t: [String]) -> [String] { (1...max(1, t.count)).map { Array(t.prefix($0)).joined(separator: " ") } }
        for (_, t) in toks { for k in Set(keys(t)) { count[k, default: 0] += 1 } }
        var out: [String: String] = [:]
        for (name, t) in toks {
            let best = keys(t).reversed().first { k in
                (count[k] ?? 0) >= 2 && k.count >= 3 && !generic.contains(k.lowercased()) && !k.allSatisfy { $0.isNumber || $0 == " " }
            }
            if let best { out[name] = best }
        }
        return out
    }

    static func role(for filename: String, layout: ProjectLayout) -> String? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let lower = filename.lowercased()
        if ["render", "рендер"].contains(where: lower.contains) { return layout.renders }
        if ["final", "export", "экспорт", "итог", "master"].contains(where: lower.contains) { return layout.exports }
        if editExt.contains(ext) { return layout.edit }
        if audioExt.contains(ext) { return layout.audio }
        return layout.sources
    }
}
