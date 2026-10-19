import Foundation

public struct ApplyReport: Sendable {
    public struct Item: Sendable { public var move: PlannedMove; public var reason: String }
    public var dryRun: Bool
    public var journalID: String?
    public var moved: [PlannedMove]
    public var skipped: [Item]
    public var failed: [Item]
    public var createdFolders: [String]
    public var movedBytes: Int64 { moved.reduce(0) { $0 + $1.bytes } }
}

public struct UndoReport: Sendable {
    public var dryRun: Bool
    public var restored: Int
    /// Things that could not be put back, with the reason. Never overwritten, never deleted.
    public var failed: [(path: String, reason: String)]
    public var removedFolders: [String]
    public var keptFolders: [String]
    /// Parent folders that had to be recreated because they were gone.
    public var recreatedFolders: [String]
}

/// Performs moves only. It never deletes (apart from removing folders it created itself, once empty, on undo)
/// and it never overwrites. Dry-run by default, like `Cleaner`.
public struct StructureExecutor: Sendable {
    public var environment: DoCleanEnvironment
    public var journals: JournalStore

    public init(environment: DoCleanEnvironment, journals: JournalStore? = nil) {
        self.environment = environment
        self.journals = journals ?? .default(home: environment.home)
    }

    /// Resolves symlinks of the nearest existing ancestor, so a not-yet-created folder is judged by where it would really land.
    static func resolved(_ path: String) -> String {
        var rest: [String] = []
        var p = path
        while !FileManager.default.fileExists(atPath: p), p.count > 1 { rest.append((p as NSString).lastPathComponent); p = (p as NSString).deletingLastPathComponent }
        var base = StructurePlanner.realPath(p)
        for r in rest.reversed() { base += "/" + r }
        return base
    }

    static func exists(_ path: String) -> Bool {
        var st = stat(); return lstat(path, &st) == 0
    }

    // MARK: apply

    public func apply(_ plan: MovePlan, dryRun: Bool = true, progress: (@Sendable (PlannedMove) -> Void)? = nil) async -> ApplyReport {
        let guardrail = environment.guardrail.relaxedForTools()
        let fm = FileManager.default
        var report = ApplyReport(dryRun: dryRun, journalID: nil, moved: [], skipped: [], failed: [], createdFolders: [])
        let rootsResolved = Dictionary(uniqueKeysWithValues: plan.sources.map { ($0, StructurePlanner.realPath($0)) })
        var writer: JournalWriter?
        if !dryRun && !plan.isEmpty {
            let id = ISO8601DateFormatter().string(from: environment.now()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(6)
            do { writer = try journals.begin(id: id, date: environment.now(), presetTitle: plan.presetTitle.en, sources: plan.sources); report.journalID = id }
            catch { report.failed.append(.init(move: Self.placeholder(), reason: "journal: \(error)")); return report }
        }
        defer { writer?.close() }

        func inside(_ path: String, _ root: String) -> Bool {
            guard let r = rootsResolved[root] else { return false }
            return SafetyGuard.isInside(Self.resolved(path), of: r)
        }

        func ensureFolder(_ path: String, root: String) -> String? {
            guard inside(path, root), (try? guardrail.checkPath(URL(fileURLWithPath: path))) != nil else { return "folder outside the source or forbidden: \(path)" }
            if Self.exists(path) {
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? nil : "a file is in the way: \(path)"
            }
            if let parentErr = ensureFolder((path as NSString).deletingLastPathComponent, root: root), (path as NSString).deletingLastPathComponent.count > root.count { return parentErr }
            if dryRun { report.createdFolders.append(path); return nil }
            do {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
                report.createdFolders.append(path)
                try? writer?.write(JournalLine(type: "folder", path: path))
                return nil
            } catch { return "\(error.localizedDescription)" }
        }

        for folder in plan.newFolders {
            if Task.isCancelled { break }
            if let root = plan.sources.first(where: { folder.hasPrefix($0 + "/") }), let err = ensureFolder(folder, root: root) {
                report.failed.append(.init(move: Self.placeholder(path: folder), reason: err))
            }
        }

        var taken = Set<String>()
        for planned in plan.moves {
            if Task.isCancelled { break }
            var m = planned
            let src = URL(fileURLWithPath: m.source)
            func skip(_ why: String) { report.skipped.append(.init(move: planned, reason: why)) }

            guard rootsResolved[m.root] != nil, SafetyGuard.isInside(m.source, of: m.root) else { skip("source is outside the chosen folder"); continue }
            var st = stat()
            guard lstat(m.source, &st) == 0 else { skip("source is gone"); continue }
            if (st.st_mode & S_IFMT) == S_IFLNK { skip("source became a symlink"); continue }
            if StructurePlanner.realPath(m.source) == rootsResolved[m.root] || StructurePlanner.realPath(m.destination) == rootsResolved[m.root] { skip("refuses to move the chosen folder itself"); continue }
            guard inside(m.source, m.root) else { skip("source resolves outside the chosen folder"); continue }
            if (try? guardrail.checkPath(src)) == nil { skip("forbidden path"); continue }
            if environment.exclusions.blocks(src) { skip("excluded"); continue }
            if let was = m.modified, let now = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               abs(now.timeIntervalSince(was)) > 0.5 { skip("changed since the plan"); continue }

            let folder = (m.destination as NSString).deletingLastPathComponent
            if let err = ensureFolder(folder, root: m.root) { skip(err); continue }
            // Never overwrite: if something appeared at the destination meanwhile, take the next free " N" name.
            if Self.exists(m.destination) || taken.contains(m.destination.lowercased()) {
                m.destination = StructurePlanner.freeName(in: folder, name: m.name, isDirectory: m.isDirectory, taken: &taken, fm: fm)
            } else { taken.insert(m.destination.lowercased()) }
            guard inside(m.destination, m.root), (try? guardrail.checkPath(URL(fileURLWithPath: m.destination))) != nil else { skip("destination not allowed"); continue }

            if dryRun { report.moved.append(m); progress?(m); continue }
            do {
                // Journal first (intent), then move: after a crash, undo checks what really exists.
                try writer?.write(JournalLine(type: "move", move: JournalMove(from: m.source, to: m.destination, root: m.root, isDirectory: m.isDirectory, bytes: m.bytes)))
                try fm.moveItem(atPath: m.source, toPath: m.destination)
                report.moved.append(m); progress?(m)
            } catch {
                report.failed.append(.init(move: m, reason: error.localizedDescription))
            }
        }
        try? writer?.write(JournalLine(type: "end", date: environment.now()), sync: true)
        return report
    }

    static func placeholder(path: String = "") -> PlannedMove {
        PlannedMove(source: path, destination: path, root: "", name: (path as NSString).lastPathComponent, isDirectory: true, isUnit: false, bytes: 0, modified: nil, ruleName: "")
    }

    // MARK: undo

    /// Puts everything back where it was. Reports (never forces) whatever cannot be restored.
    public func undo(_ journal: StructureJournal, dryRun: Bool = true) async -> UndoReport {
        let guardrail = environment.guardrail.relaxedForTools()
        let fm = FileManager.default
        var r = UndoReport(dryRun: dryRun, restored: 0, failed: [], removedFolders: [], keptFolders: [], recreatedFolders: [])
        if journal.isUndone { r.failed.append((journal.id, "already undone")); return r }

        let roots = Set(journal.moves.map(\.root) + journal.sources)
        func insideSomeRoot(_ p: String) -> Bool { roots.contains { SafetyGuard.isInside(Self.resolved(p), of: StructurePlanner.realPath($0)) } }

        for m in journal.moves.reversed() {
            if Task.isCancelled { break }
            guard insideSomeRoot(m.from), insideSomeRoot(m.to),
                  (try? guardrail.checkPath(URL(fileURLWithPath: m.from))) != nil, (try? guardrail.checkPath(URL(fileURLWithPath: m.to))) != nil else {
                r.failed.append((m.to, "journal entry points outside the chosen folder")); continue
            }
            let toExists = Self.exists(m.to), fromExists = Self.exists(m.from)
            if !toExists {
                if fromExists { continue }            // the intent was logged but the move never happened
                r.failed.append((m.to, "no longer there (moved or deleted since)")); continue
            }
            if fromExists { r.failed.append((m.to, "original place is occupied: \(m.from)")); continue }
            let parent = (m.from as NSString).deletingLastPathComponent
            if !Self.exists(parent) {
                if !dryRun { do { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) } catch { r.failed.append((m.to, "cannot recreate \(parent)")); continue } }
                r.recreatedFolders.append(parent)
            }
            if dryRun { r.restored += 1; continue }
            do { try fm.moveItem(atPath: m.to, toPath: m.from); r.restored += 1 }
            catch { r.failed.append((m.to, error.localizedDescription)) }
        }

        // Remove only the folders this run created, deepest first, only when empty.
        for folder in journal.folders.reversed() {
            guard insideSomeRoot(folder), Self.exists(folder) else { continue }
            let kids = (try? fm.contentsOfDirectory(atPath: folder)) ?? ["?"]
            let onlyMetadata = !kids.isEmpty && kids.allSatisfy { $0 == ".DS_Store" }
            if kids.isEmpty || onlyMetadata {
                if dryRun { r.removedFolders.append(folder); continue }
                // rmdir only removes an EMPTY directory, so a file that appeared meanwhile can never be lost.
                if onlyMetadata { unlink(folder + "/.DS_Store") }
                if rmdir(folder) == 0 { r.removedFolders.append(folder) } else { r.keptFolders.append(folder) }
            } else { r.keptFolders.append(folder) }
        }
        if !dryRun && r.failed.isEmpty { try? journals.appendUndo(journal.id, date: environment.now()) }
        return r
    }
}
