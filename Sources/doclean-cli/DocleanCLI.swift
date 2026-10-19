import Foundation
import DoCleanCore

/// `doclean scan [--tier green|yellow|red|all] [--json]`
/// `doclean clean --dry-run [--rules id,...] [--tier ...]`
/// `doclean clean --yes --rules id,...`   (real deletion; never run by tests or the overnight build)
/// `doclean rules`
@main
struct DocleanCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else { return usage(exit: 0) }
        let opts = Array(args.dropFirst())
        do {
            switch cmd {
            case "--version", "version": print("doclean \(DoCleanCore.version)")
            case "scan": try await scan(opts)
            case "clean": try await clean(opts)
            case "rules": try listRules()
            case "tools": try await tools(opts)
            case "structurize": try await structurize(opts)
            case "selftest": await selftest()
            case "-h", "--help", "help": usage(exit: 0)
            default: fail("unknown command: \(cmd)")
            }
        } catch {
            fail("\(error)")
        }
    }

    // MARK: helpers

    static func usage(exit code: Int32) {
        print("""
        doclean — do clean command line
          doclean scan [--tier green|yellow|red|all] [--json]
          doclean clean --dry-run [--rules id,id] [--tier green|yellow|red|all]
          doclean clean --yes --rules id,id      (really deletes; --rules is mandatory)
          doclean rules
          doclean structurize plan --preset type|date|creative|minimal --source DIR [--source DIR] [--recursive] [--lang ru|en] [--json]   (read-only)
          doclean structurize apply --preset … --source DIR --yes       (moves files; journaled, undoable)
          doclean structurize undo --yes [--journal ID] | list
          doclean selftest                      (everything on a temp fake home; exit 1 on any failure)
          doclean tools large|dupes|downloads|old [--json] [--min-mb N] [--days N] [--filter 30|90|installers|all]   (read-only)
        """)
        Foundation.exit(code)
    }

    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("doclean: \(msg)\n".utf8))
        Foundation.exit(2)
    }

    static func value(_ flag: String, in opts: [String]) -> String? {
        guard let i = opts.firstIndex(of: flag), i + 1 < opts.count else { return nil }
        return opts[i + 1]
    }

    static func rules(for opts: [String]) throws -> [Rule] {
        var all = try RuleCatalog.loadWithUserRules()
        if let t = value("--tier", in: opts), t != "all" {
            guard let tier = Tier(rawValue: t) else { fail("bad --tier \(t)") }
            all = all.filter { $0.tier == tier }
        }
        return all
    }

    static func listRules() throws {
        for r in try RuleCatalog.loadWithUserRules() {
            print("\(r.tier.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))\(r.id.padding(toLength: 26, withPad: " ", startingAt: 0))\(r.title.ru)")
        }
    }

    // MARK: scan

    static func scan(_ opts: [String]) async throws {
        let env = DoCleanEnvironment.live()
        let result = await CleanScanner(environment: env).scan(rules: try rules(for: opts))
        if opts.contains("--json") {
            FileHandle.standardOutput.write(try ScanExport(result).jsonData())
            print()
            return
        }
        for group in result.grouped() {
            print("\n== \(group.tier.rawValue.uppercased())  \(formatBytes(group.bytes))")
            for cat in group.categories {
                for r in cat.results {
                    let flag = r.status == .blockedByRunningApp ? "  [close: \(r.blockedBy.joined(separator: ", "))]" : ""
                    print("  \(formatBytes(r.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.id.padding(toLength: 26, withPad: " ", startingAt: 0)) \(r.rule.title.ru)\(flag)")
                }
            }
        }
        print("\nTotal: \(formatBytes(result.totalBytes))  green \(formatBytes(result.bytes(tier: .green)))  yellow \(formatBytes(result.bytes(tier: .yellow)))  red \(formatBytes(result.bytes(tier: .red)))  blocked by running apps: \(formatBytes(result.blockedBytes))")
    }

    // MARK: clean

    static func clean(_ opts: [String]) async throws {
        let dry = opts.contains("--dry-run")
        let yes = opts.contains("--yes")
        if dry && yes { fail("--dry-run and --yes are mutually exclusive") }
        if !dry && !yes { fail("refusing to run: pass --dry-run to preview, or --yes (with --rules) to really clean") }
        let ids = value("--rules", in: opts).map { Set($0.split(separator: ",").map(String.init)) }
        if yes && ids == nil { fail("real clean needs an explicit --rules id,id") }

        let env = DoCleanEnvironment.live()
        var rules = try rules(for: opts)
        if let ids {
            let known = Set(rules.map(\.id))
            if let bad = ids.first(where: { !known.contains($0) }) { fail("unknown rule: \(bad)") }
            rules = rules.filter { ids.contains($0.id) }
        } else {
            rules = rules.filter { $0.tier == .green }   // default dry-run plan: the safe tier
        }
        let scan = await CleanScanner(environment: env).scan(rules: rules)
        let requests = scan.requests(ruleIDs: Set(rules.map(\.id)))
        let cleaner = Cleaner(environment: env, history: History(fileURL: History.defaultURL(home: env.home)))
        let report = await cleaner.clean(requests, dryRun: dry)

        print(dry ? "DRY RUN — nothing is deleted.\n" : "CLEAN\n")
        for e in report.entries {
            let tag: String
            switch e.outcome {
            case .wouldRemove: tag = "would \(e.method.rawValue)"
            case .removed: tag = "\(e.method.rawValue)d"
            case .skipped(let why): tag = "skip (\(why))"
            case .failed(let why): tag = "FAILED (\(why))"
            }
            print("  \(formatBytes(e.item.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(tag.padding(toLength: 14, withPad: " ", startingAt: 0)) \(e.ruleID): \(e.item.path ?? e.item.name)")
        }
        for r in scan.results where r.status == .blockedByRunningApp {
            print("  blocked: \(r.id) (\(formatBytes(r.bytes))) — close \(r.blockedBy.joined(separator: ", "))")
        }
        print("\n\(dry ? "Would free" : "Freed"): \(formatBytes(report.freedBytes))  skipped: \(report.skipped.count)  failed: \(report.failed.count)")
    }

    // MARK: tools (read-only)

    static func emit<T: Encodable>(_ value: T) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try enc.encode(value)); print()
    }

    static func tools(_ opts: [String]) async throws {
        guard let tool = opts.first else { fail("tools needs one of: large dupes downloads old") }
        let rest = Array(opts.dropFirst())
        let json = rest.contains("--json")
        let env = DoCleanEnvironment.live()
        let mb = value("--min-mb", in: rest).flatMap { Int64($0) }
        let days = value("--days", in: rest).flatMap { Int($0) }
        let stderrProgress: ToolProgressHandler = { p in
            FileHandle.standardError.write(Data("\r\(p.phase) \(p.filesVisited)  ".utf8))
        }
        func line(_ b: Int64, _ d: Date?, _ p: String) -> String {
            "  \(formatBytes(b).padding(toLength: 10, withPad: " ", startingAt: 0)) \(d.map { ISO8601DateFormatter().string(from: $0).prefix(10) } ?? "----------")  \(p)"
        }
        switch tool {
        case "large":
            let f = LargeFilesFinder(environment: env, minBytes: (mb ?? 500) * 1_000_000)
            let files = await f.find(progress: json ? nil : stderrProgress)
            if json { try emit(files) } else { files.forEach { print(line($0.bytes, $0.lastOpened ?? $0.modified, $0.path)) } }
        case "old":
            let f = OldFilesFinder(environment: env, minBytes: (mb ?? 50) * 1_000_000, olderThanDays: days ?? 365)
            let files = await f.find(progress: json ? nil : stderrProgress)
            if json { try emit(files) } else { files.forEach { print(line($0.bytes, $0.lastUsedOrModified, $0.path)) } }
        case "dupes":
            let f = DuplicateFinder(environment: env, minBytes: (mb ?? 1) * 1_000_000)
            let groups = await f.find(progress: json ? nil : stderrProgress)
            struct G: Encodable { var sha256: String; var size: Int64; var reclaimableBytes: Int64; var keep: ToolFile; var duplicates: [ToolFile] }
            let out = groups.map { G(sha256: $0.sha256, size: $0.size, reclaimableBytes: $0.reclaimableBytes, keep: $0.keep, duplicates: $0.removable) }
            if json { try emit(out) } else {
                for g in groups {
                    print("\n\(formatBytes(g.reclaimableBytes)) reclaimable  (\(g.files.count) × \(formatBytes(g.size)))")
                    for (i, f) in g.files.enumerated() { print("  \(i == g.keepIndex ? "KEEP" : "    ") \(f.path)") }
                }
                print("\n\(groups.count) groups, \(formatBytes(groups.reduce(0) { $0 + $1.reclaimableBytes })) reclaimable")
            }
        case "downloads":
            let t = DownloadsTool(environment: env)
            let filterArg = value("--filter", in: rest) ?? "all"
            let filter: DownloadsFilter = filterArg == "installers" ? .installers : (Int(filterArg).map { .olderThan(days: $0) } ?? .all)
            let items = await t.find(filter)
            struct D: Encodable { var file: ToolFile; var isInstaller: Bool; var isDirectory: Bool }
            if json { try emit(items.map { D(file: $0.file, isInstaller: $0.isInstaller, isDirectory: $0.isDirectory) }) }
            else { items.forEach { print(line($0.file.bytes, $0.reference, $0.file.path + ($0.isInstaller ? "  [installer]" : ""))) } }
        default: fail("unknown tool: \(tool)")
        }
    }

    // MARK: structurize

    static func structurize(_ opts: [String]) async throws {
        guard let sub = opts.first else { fail("structurize needs: plan | apply | undo | list") }
        let rest = Array(opts.dropFirst())
        let homeOverride = value("--home", in: rest).map { URL(fileURLWithPath: $0) }
        let env = DoCleanEnvironment.live(home: homeOverride)
        let lang: Language = value("--lang", in: rest) == "en" ? .en : .ru
        let store = JournalStore.default(home: env.home)
        let exec = StructureExecutor(environment: env, journals: store)

        func sources() -> [URL] {
            var out: [URL] = []
            var i = 0
            while i < rest.count { if rest[i] == "--source", i + 1 < rest.count { out.append(URL(fileURLWithPath: (rest[i + 1] as NSString).expandingTildeInPath)); i += 1 }; i += 1 }
            if out.isEmpty { fail("--source DIR is required") }
            return out
        }
        func preset() -> StructurePreset {
            guard let name = value("--preset", in: rest), let p = StructurePreset.builtIn(cliName: name, language: lang) else { fail("--preset type|date|creative|minimal") }
            return p
        }
        func makePlan() async throws -> MovePlan {
            try await StructurePlanner(environment: env).plan(sources: sources(), preset: preset(), options: PlanOptions(recursive: rest.contains("--recursive"), language: lang))
        }

        switch sub {
        case "plan":
            let plan = try await makePlan()
            if rest.contains("--json") {
                struct S: Encodable { var folder: String; var count: Int; var bytes: Int64 }
                struct Out: Encodable { var preset: String; var sources: [String]; var count: Int; var bytes: Int64; var summary: [S]
                    var newFolders: [String]; var moves: [PlannedMove]; var skipped: [SkippedEntry] }
                try emit(Out(preset: plan.presetID, sources: plan.sources, count: plan.count, bytes: plan.bytes,
                             summary: plan.summary().map { S(folder: $0.folder, count: $0.count, bytes: $0.bytes) },
                             newFolders: plan.newFolders, moves: plan.moves, skipped: plan.skipped))
            } else {
                print("PLAN — nothing is moved. \(plan.count) items, \(formatBytes(plan.bytes)); skipped: \(plan.skipped.count)")
                for s in plan.summary() { print("  \(s.folder.padding(toLength: 18, withPad: " ", startingAt: 0)) \(s.count) × \(formatBytes(s.bytes))") }
                var reasons: [SkipReason: Int] = [:]
                for s in plan.skipped { reasons[s.reason, default: 0] += 1 }
                if !reasons.isEmpty { print("  skipped: " + reasons.sorted { $0.value > $1.value }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", ")) }
            }
        case "apply":
            guard rest.contains("--yes") else { fail("apply moves files; pass --yes (use `plan` first)") }
            let report = await exec.apply(try await makePlan(), dryRun: false)
            print("moved \(report.moved.count) (\(formatBytes(report.movedBytes))), skipped \(report.skipped.count), failed \(report.failed.count). Journal: \(report.journalID ?? "-")")
            for f in report.failed { print("  FAILED \(f.move.name): \(f.reason)") }
        case "undo":
            guard rest.contains("--yes") else { fail("undo moves files back; pass --yes") }
            let journal = value("--journal", in: rest).flatMap { store.load(id: $0) } ?? store.latestUndoable()
            guard let journal else { fail("no journal to undo") }
            let r = await exec.undo(journal, dryRun: false)
            print("restored \(r.restored), removed folders \(r.removedFolders.count), kept \(r.keptFolders.count), failed \(r.failed.count)")
            for f in r.failed { print("  could not restore \(f.path): \(f.reason)") }
        case "list":
            for j in store.list() { print("\(j.id)  \(j.presetTitle)  \(j.moves.count) moves\(j.isUndone ? "  (undone)" : "")") }
        default: fail("unknown structurize command: \(sub)")
        }
    }

    static func selftest() async {
        let t = await SelfTest.run()
        for c in t.checks where !c.passed { print("FAIL  \(c.name)  \(c.detail)") }
        print("selftest: \(t.checks.count - t.failures.count) passed, \(t.failures.count) failed (\(t.checks.count) checks)")
        Foundation.exit(t.failures.isEmpty ? 0 : 1)
    }
}
