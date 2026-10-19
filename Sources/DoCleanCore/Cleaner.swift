import Foundation

public enum CleanOutcome: Sendable, Equatable {
    case removed          // really done
    case wouldRemove      // dry run
    case skipped(String)  // safety check / app running; nothing touched
    case failed(String)   // attempted but the OS or tool said no
}

public struct CleanEntry: Sendable, Identifiable {
    public var id: String { ruleID + "|" + item.id }
    public var ruleID: String
    public var item: ScanItem
    public var method: DeletionMethod
    public var outcome: CleanOutcome
    public var freedBytes: Int64 {
        switch outcome { case .removed, .wouldRemove: item.bytes; default: 0 }
    }
}

public struct CleanReport: Sendable {
    public var entries: [CleanEntry]
    public var dryRun: Bool
    public var freedBytes: Int64 { entries.reduce(0) { $0 + $1.freedBytes } }
    public var skipped: [CleanEntry] { entries.filter { if case .skipped = $0.outcome { true } else { false } } }
    public var failed: [CleanEntry] { entries.filter { if case .failed = $0.outcome { true } else { false } } }
}

/// Moves something to the Trash. Injectable so tests never touch the real Trash.
public protocol Trasher: Sendable { func trash(_ url: URL) throws }

public struct FileManagerTrasher: Trasher {
    public init() {}
    public func trash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
}

public struct Cleaner: Sendable {
    public let environment: DoCleanEnvironment
    public let trasher: any Trasher
    public let history: History?
    /// How green-tier `.delete` rules are carried out: permanently or via the Trash.
    public let greenMethod: DeletionMethod

    public init(environment: DoCleanEnvironment, trasher: any Trasher = FileManagerTrasher(), history: History? = nil,
                greenMethod: DeletionMethod = .delete) {
        self.environment = environment; self.trasher = trasher; self.history = history
        self.greenMethod = greenMethod == .trash ? .trash : .delete
    }

    /// Cleans the requests. **`dryRun` defaults to true**: nothing is touched unless the caller passes `false`.
    /// Every item is re-validated right before it is removed; one failure never stops the rest.
    public func clean(_ requests: [CleanRequest], dryRun: Bool = true,
                      progress: (@Sendable (CleanEntry) -> Void)? = nil) async -> CleanReport {
        var entries: [CleanEntry] = []
        var historyRows: [HistoryEntry] = []

        for req in requests {
            var rule = req.rule
            if rule.tier == .green, rule.deletion == .delete, greenMethod == .trash { rule.deletion = .trash }
            // Relaxed guard (Documents/Desktop/Pictures) only for Trash-only tool requests.
            let relaxed = req.allowUserFolders && rule.deletion == .trash
            let guardrail = relaxed ? environment.guardrail.relaxedForTools() : environment.guardrail
            let blockers = environment.probe.runningApps(matching: rule.requiresAppClosed)
            var removedBytes: Int64 = 0, removedCount = 0

            for item in req.items {
                if Task.isCancelled { break }
                var entry = CleanEntry(ruleID: rule.id, item: item, method: rule.deletion, outcome: .skipped("not run"))
                if environment.exclusions.excludes(rule: rule.id) {
                    entry.outcome = .skipped("rule excluded")
                } else if relaxed, let u = item.url, (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    entry.outcome = .skipped("tool items must be files, not folders")
                } else if let u = item.url, environment.exclusions.blocks(u) {
                    entry.outcome = .skipped("excluded path")
                } else if req.allowUserFolders && rule.deletion != .trash {
                    entry.outcome = .skipped("tool requests may only go to the Trash")
                } else if !blockers.isEmpty {
                    entry.outcome = .skipped("app running: \(blockers.joined(separator: ", "))")
                } else {
                    entry.outcome = process(item: item, rule: rule, guardrail: guardrail, dryRun: dryRun)
                }
                if entry.outcome == .removed { removedBytes += item.bytes; removedCount += 1 }
                entries.append(entry)
                progress?(entry)
            }
            if removedCount > 0 {
                historyRows.append(HistoryEntry(date: environment.now(), ruleID: rule.id, bytes: removedBytes,
                                                itemCount: removedCount, method: rule.deletion))
            }
        }
        if !dryRun { try? history?.append(historyRows) }
        return CleanReport(entries: entries, dryRun: dryRun)
    }

    private func process(item: ScanItem, rule: Rule, guardrail: SafetyGuard, dryRun: Bool) -> CleanOutcome {
        // Command items
        if item.isCommand {
            guard rule.deletion == .command else { return .skipped("command item on a path rule") }
            do { try guardrail.checkCommand(rule.command) } catch { return .skipped("\(error)") }
            guard let exe = environment.runner.locate(rule.command[0]) else { return .skipped("\(rule.command[0]) not installed") }
            if dryRun { return .wouldRemove }
            let out = environment.runner.run(exe, Array(rule.command.dropFirst()))
            return out.status == 0 ? .removed : .failed("exit \(out.status)")
        }
        guard rule.deletion != .command, let url = item.url else { return .skipped("path item on a command rule") }
        guard let scanned = item.fingerprint else { return .skipped("no scan fingerprint") }

        let roots = rule.roots.map(environment.expand)
        do {
            try guardrail.check(item: url, roots: roots, allowRootItself: rule.itemMode == .root,
                                scannedFingerprint: scanned, currentFingerprint: FileMeasure.fingerprint(url))
        } catch {
            return .skipped("\(error)")
        }
        if dryRun { return .wouldRemove }
        do {
            switch rule.deletion {
            case .delete: try FileManager.default.removeItem(at: url)
            case .trash: try trasher.trash(url)
            case .command: return .skipped("unreachable")
            }
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
