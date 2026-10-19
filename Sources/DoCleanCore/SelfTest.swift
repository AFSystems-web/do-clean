import Foundation

/// `doclean selftest`: runs everything on a FAKE home in a temp folder. It never touches the real home:
/// the environment's home and temp bases are the temp folder only, and the Trash is a folder inside it.
public struct SelfTest: Sendable {
    public struct Check: Sendable { public var name: String; public var passed: Bool; public var detail: String }
    public private(set) var checks: [Check] = []
    public var failures: [Check] { checks.filter { !$0.passed } }

    public init() {}

    mutating func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        checks.append(Check(name: name, passed: ok, detail: ok ? "" : detail()))
    }

    // MARK: fake machine

    struct ScriptedRunner: CommandRunner {
        func locate(_ name: String) -> String? { ["xcrun", "brew", "docker"].contains(name) ? "/fake/\(name)" : nil }
        func run(_ exe: String, _ args: [String]) -> CommandOutput {
            // Dry-run scans are answered from a script; real commands only record "ok" (nothing is executed).
            switch args.joined(separator: " ") {
            case "cleanup -n --prune=all": return CommandOutput(status: 0, stdout: "approximately 10MB of disk space")
            case "system df --format {{json .}}": return CommandOutput(status: 0, stdout: #"{"Type":"Images","Reclaimable":"1GB (50%)"}"#)
            default: return CommandOutput(status: 0, stdout: #"{"devices":{}}"#)
            }
        }
    }

    struct TempTrasher: Trasher {
        let trash: URL
        func trash(_ url: URL) throws {
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
    }

    static func write(_ url: URL, size: Int = 20_000, ageDays: Double = 40, fill: UInt8 = 0) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(repeating: fill, count: size).write(to: url)
        let d = Date().addingTimeInterval(-ageDays * 86_400)
        try? fm.setAttributes([.modificationDate: d], ofItemAtPath: url.path)
        var dir = url.deletingLastPathComponent()
        for _ in 0..<12 where dir.pathComponents.count > 4 { try? fm.setAttributes([.modificationDate: d], ofItemAtPath: dir.path); dir = dir.deletingLastPathComponent() }
    }

    static func snapshot(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = StructurePlanner.realPath(root.path)
        let en = FileManager.default.enumerator(at: URL(fileURLWithPath: base), includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
        while let u = en?.nextObject() as? URL {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            out[String(u.path.dropFirst(base.count))] = v?.isDirectory == true ? "d" : "f\(v?.fileSize ?? -1)"
        }
        return out
    }

    // MARK: run

    public static func run() async -> SelfTest {
        var t = SelfTest()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: StructurePlanner.realPath(NSTemporaryDirectory())).appendingPathComponent("doclean-selftest-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true), tmp = root.appendingPathComponent("tmp", isDirectory: true)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        for d in [home, tmp, trash] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }
        t.check("fake home is NOT the real home", home.path != FileManager.default.homeDirectoryForCurrentUser.path && !home.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/"))

        let env = DoCleanEnvironment(home: home, tmpDir: tmp, externalBases: [tmp], probe: FixedAppStateProbe(), runner: ScriptedRunner())
        let guardrail = env.guardrail
        let rules: [Rule]
        do { rules = try RuleCatalog.load() } catch { t.check("catalog loads", false, "\(error)"); return t }
        t.check("catalog loads", rules.count >= 30, "\(rules.count) rules")

        // Sentinels that must survive everything.
        let sentinels = ["Documents/thesis.docx", "Desktop/notes.txt", "Pictures/Photos Library.photoslibrary/a.heic", "Library/Keychains/login.keychain-db",
                         "Library/Application Support/Google/Chrome/Default/Login Data", "Library/Mobile Documents/com~apple~CloudDocs/x.pdf", ".ssh/id_ed25519"]
        for s in sentinels { write(home.appendingPathComponent(s), size: 777, ageDays: 900) }
        func sentinelsIntact() -> Bool { sentinels.allSatisfy { (try? Data(contentsOf: home.appendingPathComponent($0)).count) == 777 } }

        // 1. SafetyGuard invariants
        for rel in ["Documents", "Desktop", "Pictures", "Library/Keychains", "Library/Application Support/Google", "Library/Mobile Documents", ".ssh"] {
            t.check("guard forbids ~/\(rel)", (try? guardrail.checkPath(home.appendingPathComponent(rel))) == nil)
        }
        for bad in [home, home.appendingPathComponent("Library"), URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/System"), URL(fileURLWithPath: "/Users")] {
            t.check("guard refuses \(bad.path == home.path ? "home" : bad.path)", (try? guardrail.checkPath(bad)) == nil)
        }
        for r in rules { for root in r.roots {
            let u = env.expand(root)
            let ok = (try? guardrail.checkRoot(u)) != nil || root.hasPrefix("/")     // absolute /tmp is judged against the fake bases
            t.check("root of \(r.id) passes guard: \(root)", ok)
        } }
        let realEnv = DoCleanEnvironment.live()
        for r in rules { for root in r.roots { t.check("real-machine root of \(r.id) passes guard", (try? realEnv.guardrail.checkRoot(realEnv.expand(root))) != nil, root) } }

        // 2. Populate every standard rule, then scan → dry clean → real clean (on the fake home)
        let standard = rules.filter { $0.kind == .standard && !$0.roots.contains { $0.hasPrefix("/") } }
        for r in standard { for (i, rootStr) in r.roots.enumerated() {
            let r0 = env.expand(rootStr)
            let name = (r.patterns.first ?? "child").replacingOccurrences(of: "*", with: "x") + "\(i)"
            switch r.itemMode {
            case .root: write(r0.appendingPathComponent("a.bin"))
            case .files: write(r0.appendingPathComponent(name))
            case .children:
                var rel = name
                for _ in 1..<max(1, r.childDepth) { rel = "pub/" + rel }
                write(r0.appendingPathComponent(rel + "/data.bin"))
            }
        } }
        write(home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport/iPhone14,2 17.0 (21A329)/s.bin"))
        write(home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport/iPhone14,2 18.0 (22A3354)/s.bin"))
        write(home.appendingPathComponent(".cache/huggingface/hub/models--a--b/blobs/x"))
        write(home.appendingPathComponent("Developer/old/package.json"), size: 100, ageDays: 90)
        write(home.appendingPathComponent("Developer/old/node_modules/x/i.js"), ageDays: 90)
        write(home.appendingPathComponent("Movies/Lib.fcpbundle/Event/Render Files/r.mov"))

        let beforeAll = snapshot(home)
        let scan = await CleanScanner(environment: env).scan(rules: rules)
        t.check("scan finds something", scan.totalBytes > 0)
        for r in standard { let res = scan.result(id: r.id); t.check("rule \(r.id) finds its files", res?.status == .ready && (res?.bytes ?? 0) > 0, "\(String(describing: res?.status))") }
        for id in ["ios-device-support", "huggingface", "node-modules", "fcp-render-files", "homebrew-cleanup", "docker"] {
            t.check("special rule \(id) works", scan.result(id: id)?.status == .ready, "\(String(describing: scan.result(id: id)?.status))")
        }
        t.check("scan is read-only", snapshot(home) == beforeAll)
        t.check("newest DeviceSupport is kept", scan.result(id: "ios-device-support")?.items.count == 1 && (scan.result(id: "ios-device-support")?.protectedBytes ?? 0) > 0)

        let cleaner = Cleaner(environment: env, trasher: TempTrasher(trash: trash), history: History(fileURL: root.appendingPathComponent("history.json")))
        let all = scan.requests(ruleIDs: Set(rules.map(\.id)))
        let dry = await cleaner.clean(all)
        t.check("dry clean plans every item", dry.entries.allSatisfy { $0.outcome == .wouldRemove }, "\(dry.skipped.count) skipped")
        t.check("dry clean touches nothing", snapshot(home) == beforeAll)
        let real = await cleaner.clean(all, dryRun: false)
        t.check("real clean removed items", real.entries.contains { $0.outcome == .removed } && real.failed.isEmpty, "\(real.failed.count) failed")
        t.check("sentinels survive the clean", sentinelsIntact())
        t.check("history recorded", History(fileURL: root.appendingPathComponent("history.json")).totalFreed == real.freedBytes)
        t.check("home itself and system folders still exist", fm.fileExists(atPath: home.path) && fm.fileExists(atPath: home.appendingPathComponent("Documents").path))

        // 3. Tools
        write(home.appendingPathComponent("Movies/big.mov"), size: 3_000_000, ageDays: 500)
        let dupBytes = Data(repeating: 9, count: 300_000)
        for rel in ["Documents/a/dup.bin", "Desktop/dup.bin", "Downloads/dup.bin"] { try? fm.createDirectory(at: home.appendingPathComponent(rel).deletingLastPathComponent(), withIntermediateDirectories: true); try? dupBytes.write(to: home.appendingPathComponent(rel)) }
        write(home.appendingPathComponent("Downloads/Setup.dmg"), size: 5000, ageDays: 100)
        let toolEnv = env
        let large = await LargeFilesFinder(environment: toolEnv, minBytes: 1_000_000, dates: NoFileDates()).find()
        t.check("large files tool", large.contains { $0.name == "big.mov" })
        let old = await OldFilesFinder(environment: toolEnv, minBytes: 1_000_000, dates: NoFileDates()).find()
        t.check("old files tool", old.contains { $0.name == "big.mov" })
        let dupFinder = DuplicateFinder(environment: toolEnv, minBytes: 100_000, dates: NoFileDates())
        let groups = await dupFinder.find()
        t.check("duplicates tool", groups.count == 1 && groups[0].files.count == 3 && groups[0].keep.name == "dup.bin" && !groups[0].keep.path.contains("/Downloads/"))
        let dl = DownloadsTool(environment: toolEnv, dates: NoFileDates())
        let installers = await dl.find(.installers)
        t.check("downloads tool", installers.map(\.file.name) == ["Setup.dmg"])
        write(home.appendingPathComponent("Developer/old/node_modules/x/i.js"), ageDays: 90)   // the rule clean above already removed it
        let nm = await NodeModulesFinder(environment: toolEnv, olderThanDays: 30).find()
        t.check("node_modules tool", nm?.projects.count == 1, "")
        let snapTools = snapshot(home)
        let toolRequests = [LargeFilesFinder(environment: toolEnv).cleanRequest(large), dupFinder.find0(groups), dl.cleanRequest(installers)].compactMap { $0 }
        let dryTools = await cleaner.clean(toolRequests)
        t.check("tool dry run touches nothing", snapshot(home) == snapTools && dryTools.entries.allSatisfy { $0.outcome == .wouldRemove }, "\(dryTools.skipped.count) skipped")
        let realTools = await cleaner.clean(toolRequests, dryRun: false)
        t.check("tools clean via Trash only", realTools.entries.allSatisfy { $0.outcome == .removed && $0.method == .trash }, "\(realTools.failed.count) failed")
        t.check("one duplicate copy always survives", groups.first.map { fm.fileExists(atPath: $0.keep.path) } ?? false)
        t.check("sentinels survive the tools", sentinelsIntact())

        // 4. Structurize: every preset, plan → dry → apply → undo → identical
        let presets = StructurePreset.builtIn(language: .ru) + StructurePreset.builtIn(language: .en)
        for preset in presets {
            let sroot = home.appendingPathComponent("Sort-\(preset.id)-\(preset.title.en.count)", isDirectory: true)
            for n in ["a.mp4", "b.jpg", "c.pdf", "d.mp3", "Botanica_x.mp4", "Botanica_y.wav", "e.zip"] { write(sroot.appendingPathComponent(n), size: 3000, ageDays: 20) }
            write(sroot.appendingPathComponent("Proj/x.blend"), size: 100); write(sroot.appendingPathComponent("Proj/media/a.mov"), size: 3000)
            let before = snapshot(sroot)
            let ex = StructureExecutor(environment: env, journals: JournalStore(directory: root.appendingPathComponent("journals")))
            guard let plan = try? await StructurePlanner(environment: env).plan(sources: [sroot], preset: preset, options: PlanOptions(recursive: true)) else {
                t.check("structurize plan \(preset.id)", false); continue
            }
            t.check("structurize \(preset.id): plan finds items", plan.count > 0)
            t.check("structurize \(preset.id): nothing inside the project is planned", !plan.moves.contains { $0.source.contains("/Proj/") })
            t.check("structurize \(preset.id): plan is read-only", snapshot(sroot) == before)
            _ = await ex.apply(plan)
            t.check("structurize \(preset.id): dry run changes nothing", snapshot(sroot) == before)
            let done = await ex.apply(plan, dryRun: false)
            t.check("structurize \(preset.id): apply", done.failed.isEmpty && !done.moved.isEmpty)
            t.check("structurize \(preset.id): project untouched", fm.fileExists(atPath: sroot.appendingPathComponent("Proj/media/a.mov").path) || preset.strategy == .creative)
            if let j = ex.journals.latestUndoable() {
                let u = await ex.undo(j, dryRun: false)
                t.check("structurize \(preset.id): undo restores the identical tree", u.failed.isEmpty && snapshot(sroot) == before, "\(u.failed.count) failed")
            } else { t.check("structurize \(preset.id): journal written", false) }
        }
        t.check("sentinels survive structurize", sentinelsIntact())

        // 5. Hostile input
        let evilRoot = home.appendingPathComponent("Downloads")
        try? fm.createSymbolicLink(at: evilRoot.appendingPathComponent("evil-link"), withDestinationURL: home.appendingPathComponent("Documents"))
        let ghostItem = ScanItem(id: "x", name: "thesis.docx", path: home.appendingPathComponent("Documents/thesis.docx").path, bytes: 1, fingerprint: Date())
        let r1 = await cleaner.clean([CleanRequest(rule: rules.first { $0.id == "downloads" }!, items: [ghostItem])], dryRun: false)
        t.check("forged item outside the rule root is refused", r1.entries.first.map { if case .skipped = $0.outcome { true } else { false } } ?? false && sentinelsIntact())
        let tampered = Rule(id: "evil", title: L10n(ru: "e", en: "e"), whySafe: L10n(ru: "e", en: "e"), tier: .green, category: .system, deletion: .command, command: ["rm", "-rf", "/"])
        let r2 = await cleaner.clean([CleanRequest(rule: tampered, items: [ScanItem(id: "cmd:evil", name: "x", path: nil, bytes: 1)])], dryRun: false)
        t.check("non-allow-listed command is refused", r2.entries.first.map { if case .skipped = $0.outcome { true } else { false } } ?? false)
        t.check("sentinels survive everything", sentinelsIntact())
        return t
    }
}

private extension DuplicateFinder {
    func find0(_ groups: [DuplicateGroup]) -> CleanRequest? { groups.first?.cleanRequest() }
}
