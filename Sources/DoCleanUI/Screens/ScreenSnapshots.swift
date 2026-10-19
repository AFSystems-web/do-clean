import SwiftUI
import AppKit
import DoCleanCore

/// Renders every screen to PNG from a real, read-only scan (`-snapshot-screens <dir>`).
/// Cleaning is always a dry run here: nothing on disk is touched.
public enum ScreenSnapshots {
    public static let size = CGSize(width: 1320, height: 860)

    @MainActor
    public static func render(to dir: URL, log: (String) -> Void = { print($0) }) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Bundled rules only: personal rules from this Mac never end up in repo screenshots.
        let model = AppModel(rules: try RuleCatalog.load(), allowRealClean: false)
        model.animated = false
        model.showOnboarding = false
        model.mode = .all

        func shot(_ name: String, _ view: some View = EmptyView(), sheet: Bool = false) throws {
            let content = ZStack {
                MainView(model: model)
                if sheet {
                    Color.black.opacity(0.55)
                    ConfirmCleanSheet(model: model)
                        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(hex: 0x16161A)))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.12)))
                        .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
                }
            }
            try write(content, to: dir.appendingPathComponent(name + ".png"))
            log("snapshot: \(name).png")
        }

        // 1. Dashboard before any scan.
        try shot("dashboard-empty")

        // Shell (stage 8): onboarding, settings, history, menu bar.
        for page in 0..<3 {
            let access: AccessStatus = page == 2 ? .denied : .unknown
            try write(OnboardingView(model: model, probe: FixedAccess(access), page: page, access: access),
                      to: dir.appendingPathComponent("onboarding-\(page + 1).png"))
        }
        try write(OnboardingView(model: model, probe: FixedAccess(.granted), page: 2, access: .granted),
                  to: dir.appendingPathComponent("onboarding-granted.png"))
        model.section = .settings
        try shot("settings")
        model.historyEntriesOverride = demoHistory()
        model.section = .history
        try shot("history")
        model.section = .home
        try write(MenuBarView(model: model, openMainWindow: {}).fixedSize(), to: dir.appendingPathComponent("menubar.png"), size: nil)
        log("snapshot: shell")

        // 2. Scanning, caught mid-way.
        model.startScan()
        while model.scan.phase == .scanning && model.scan.progress < 0.45 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try shot("scanning")
        while model.scan.phase == .scanning { try await Task.sleep(for: .milliseconds(50)) }
        guard let scanned = model.scan.result else { throw GallerySnapshot.Failure.render }
        let result = anonymized(scanned)
        model.finishScan(result)

        // 3a. Dashboard with the scan in.
        model.stage = .dashboard
        try shot("dashboard")
        model.stage = .results

        // 3. Results: green expanded; then the review tiers with red files ticked by hand.
        let green = result.grouped().first?.categories.flatMap(\.results) ?? []
        if let pick = green.first(where: { (2...6).contains($0.items.count) }) ?? green.first { model.expanded = [pick.id] }
        try shot("results")

        let saved = (model.lastResult, model.selection)
        model.finishScan(ScanResult(results: result.results.filter { $0.rule.tier == .yellow }, date: result.date))
        try shot("results-review")
        let redOnly = ScanResult(results: result.results.filter { $0.rule.tier == .red }, date: result.date)
        model.finishScan(redOnly)
        if let red = redOnly.results.first(where: { $0.isCleanable }) {
            model.selection[red.id] = Set(red.items.prefix(3).map(\.id))
            model.expanded = [red.id]
        }
        try shot("results-personal")
        model.finishScan(saved.0 ?? result)
        model.selection = saved.1
        if let red = result.results.first(where: { $0.rule.tier == .red && $0.isCleanable }) {
            model.selection[red.id] = Set(red.items.prefix(3).map(\.id))
        }

        // 4. Confirm sheet.
        model.expanded = []
        try shot("confirm", sheet: true)

        // 5. Cleaning progress (state set by hand, mid-way).
        let reqs = model.requests
        let total = reqs.reduce(0) { $0 + $1.items.count }
        model.diskBefore = model.disk
        model.cleanTotalItems = total
        model.cleanDoneItems = total * 6 / 10
        model.cleanFreed = Int64(Double(model.selectedBytes) * 0.62)
        model.cleanCurrent = reqs.last?.items.first?.name
        model.stage = .cleaning
        try shot("cleaning")

        // 6. Finished: a real dry run over the selection.
        let report = await Cleaner(environment: model.environment).clean(reqs, dryRun: true)
        model.finishClean(report)
        try shot("finished")

        // Structurize (stage 11).
        try await renderStructurize(to: dir, real: model, log: log)
        model.section = .home

        // 7. Tools: real, read-only finds; names anonymized. DOCLEAN_SNAPSHOT_SKIP_TOOLS=1 skips the slow walks.
        if ProcessInfo.processInfo.environment["DOCLEAN_SNAPSHOT_SKIP_TOOLS"] == "1" { return }
        model.stage = .results
        model.section = .tools
        let tools = model.tools
        for kind in ToolKind.allCases {
            tools.current = kind
            if kind == .downloads { tools.downloadsFilter = .all }
            let start = Date()
            tools.run(kind)
            if kind == .duplicates {
                while tools.isRunning(kind) && Date().timeIntervalSince(start) < 1.2 { try await Task.sleep(for: .milliseconds(50)) }
                if tools.isRunning(kind) { try shot("tools-running") }
            }
            while tools.isRunning(kind) && Date().timeIntervalSince(start) < 240 { try await Task.sleep(for: .milliseconds(100)) }
            if tools.isRunning(kind) { tools.cancel(kind) }
            log(String(format: "tool %@: %.1f s, %d found", kind.rawValue, Date().timeIntervalSince(start), tools.foundCount(kind) ?? -1))
            anonymize(tools, kind)
            try shot("tools-" + kind.rawValue)
        }
    }

    // MARK: Structurize

    @MainActor
    static func renderStructurize(to dir: URL, real model: AppModel, log: (String) -> Void) async throws {
        func shot(_ name: String, _ app: AppModel, confirm: Bool = false) throws {
            app.section = .structurize
            let view = ZStack {
                MainView(model: app)
                if confirm {
                    Color.black.opacity(0.55)
                    StructurizeConfirmSheet(model: app, s: app.structurize)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.12)))
                        .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
                }
            }
            try write(view, to: dir.appendingPathComponent("structurize-\(name).png"))
            log("snapshot: structurize-\(name).png")
        }

        // Demo home with my own test files: the only place where a real apply/undo runs.
        let demo = try StructurizeDemo.make()
        defer { try? FileManager.default.removeItem(at: demo.home) }
        let demoApp = AppModel(environment: demo.environment, rules: model.rules, disk: model.disk,
                               settingsStore: SettingsStore(fileURL: demo.home.appendingPathComponent("settings.json")),
                               showOnboarding: false)
        demoApp.animated = false
        let ds = demoApp.structurize!
        ds.journalStoreOverride = JournalStore(directory: demo.home.appendingPathComponent("journals"))
        ds.sources = [.desktop]

        // History: two earlier layouts on the demo home (one undone).
        let exec = StructureExecutor(environment: demo.environment, journals: ds.journalStoreOverride)
        let planner = StructurePlanner(environment: demo.environment)
        let desktop = StructureSource.desktop.url(home: demo.home)
        let byDate = StructurePreset.builtIn(id: StructurePreset.byDateID)!
        let first = try await planner.plan(sources: [desktop], preset: byDate)
        let r1 = await exec.apply(first, dryRun: false)
        if let id = r1.journalID, let j = exec.journals.load(id: id) { _ = await exec.undo(j, dryRun: false) }
        let minimal = StructurePreset.builtIn(id: StructurePreset.minimalID)!
        let r2 = await exec.apply(try await planner.plan(sources: [demo.home.appendingPathComponent("Documents")], preset: minimal), dryRun: false)
        _ = r2
        ds.reloadJournals()

        // 1. Choose (real app model for sources/presets, demo history).
        let s = model.structurize!
        s.journalStoreOverride = ds.journalStoreOverride
        s.reloadJournals()
        s.select(StructurePreset.builtIn(id: StructurePreset.byTypeID)!)
        s.stage = .choose
        try shot("choose", model)

        // 2. Customize.
        s.stage = .customize
        try shot("customize", model)

        // 3. Preview «По типу» on the real Downloads (read-only), names anonymized.
        let realPlan = try await StructurePlanner(environment: model.scanEnvironment)
            .plan(sources: [StructureSource.downloads.url(home: model.environment.home)], preset: s.draft)
        log("structurize real plan: \(realPlan.count) moves, \(realPlan.skipped.count) skipped")
        s.installPlan(anonymized(realPlan))
        try shot("preview", model)
        try shot("confirm", model, confirm: true)

        // 4. Applying (state set by hand) and the dry-run «done».
        s.stage = .applying
        s.appliedCount = (s.plan?.count ?? 0) * 6 / 10
        s.currentName = s.plan?.moves.dropFirst(5).first?.name
        try shot("applying", model)
        // Dry run on the real (non-anonymized) plan: the executor re-checks real paths.
        s.finishApply(await StructureExecutor(environment: model.scanEnvironment).apply(realPlan, dryRun: true))
        try shot("done-dryrun", model)
        s.journalStoreOverride = nil
        s.restart()

        // 5. Creative on the demo home: projects move whole; real apply there → undo available.
        ds.select(StructurePreset.builtIn(id: StructurePreset.creativeID)!)
        let creative = try await planner.plan(sources: [desktop], preset: ds.draft)
        ds.installPlan(creative)
        try shot("preview-creative", demoApp)
        ds.finishApply(await exec.apply(creative, dryRun: false))
        try shot("done", demoApp)
    }

    /// Only well-known top folders survive anonymization.
    static func safeTop(_ rel: String) -> String {
        let top = rel.split(separator: "/").first.map(String.init) ?? ""
        return ["Desktop", "Documents", "Downloads", "Movies", "Pictures", "Music", "Developer"].contains(top) ? top : "Папка"
    }

    /// Neutral names for a plan on the real Downloads (screenshots go to the repo).
    static func anonymized(_ plan: MovePlan) -> MovePlan {
        var p = plan
        var n = 0
        p.moves = plan.moves.map { m in
            n += 1
            var c = m
            let ext = (m.name as NSString).pathExtension
            let name = (m.isDirectory ? "Папка \(n)" : "Файл \(n)") + (ext.isEmpty || m.isDirectory ? "" : "." + ext.lowercased())
            c.name = name
            c.source = (m.source as NSString).deletingLastPathComponent + "/" + name
            c.destination = (m.destination as NSString).deletingLastPathComponent + "/" + name
            return c
        }
        p.skipped = plan.skipped.map { e in
            n += 1
            var c = e
            c.name = "Файл \(n)"
            c.path = (e.path as NSString).deletingLastPathComponent + "/" + c.name
            return c
        }
        return p
    }

    /// Replaces names/paths in tool results so screenshots carry no personal file names.
    @MainActor
    static func anonymize(_ tools: ToolsModel, _ kind: ToolKind) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var n = 0
        func anon(_ f: ToolFile) -> ToolFile {
            n += 1
            var c = f
            let ext = (f.name as NSString).pathExtension
            c.name = "Файл \(n)" + (ext.isEmpty ? "" : "." + ext.lowercased())
            let rel = f.path.hasPrefix(home + "/") ? String(f.path.dropFirst(home.count + 1)) : "Файлы"
            let top = safeTop(rel)
            c.path = home + "/" + top + "/" + c.name
            return c
        }
        switch kind {
        case .large:
            let out = (tools.large.output ?? []).map(anon)
            tools.large.set(out)
            tools.largeSelection = Set(out.prefix(2).map(\.path))
        case .old:
            tools.old.set((tools.old.output ?? []).map(anon))
        case .downloads:
            tools.downloads.set((tools.downloads.output ?? []).map { var d = $0; d.file = anon(d.file); return d })
            tools.downloadsSelection = Set(tools.visibleDownloads.prefix(3).map(\.id))
        case .duplicates:
            let groups = (tools.duplicates.output ?? []).map { g -> DuplicateGroup in
                var c = g
                n += 1
                let ext = ((g.files.first?.name ?? "") as NSString).pathExtension
                let name = "Файл \(n)" + (ext.isEmpty ? "" : "." + ext.lowercased())
                c.files = g.files.enumerated().map { i, f in
                    var x = f
                    let rel = f.path.hasPrefix(home + "/") ? String(f.path.dropFirst(home.count + 1)) : "Файлы"
                    let top = safeTop(rel)
                    x.name = name
                    x.path = home + "/" + top + (i == 0 ? "" : "/Копия \(i)") + "/" + name
                    return x
                }
                return c
            }
            tools.duplicates.set(groups)
            tools.resetDuplicates(groups)
        case .nodeModules:
            guard var out = tools.nodeModules.output else { return }
            out.projects = out.projects.enumerated().map { i, p in
                var c = p
                c.name = "project-\(i + 1)"
                c.projectPath = home + "/Developer/project-\(i + 1)"
                return c
            }
            tools.nodeModules.set(out)
        }
    }

    /// Screenshots go to the repo: every item gets a neutral name (extension kept), so no
    /// personal files, app bundle ids or device models leak. Rule titles stay as they are.
    static func anonymized(_ result: ScanResult) -> ScanResult {
        var r = result
        r.results = result.results.map { rr in
            let base = rr.rule.category == .personal ? "Файл" : "Элемент"
            var copy = rr
            copy.items = rr.items.enumerated().map { i, item in
                var it = item
                let ext = item.fileExtension.isEmpty ? "" : "." + item.fileExtension
                it.name = "\(base) \(i + 1)\(ext)"
                it.path = item.path.map { ($0 as NSString).deletingLastPathComponent + "/" + it.name }
                return it
            }
            return copy
        }
        return r
    }

    /// Clearly synthetic history for the History screenshot (this Mac has no real cleanups yet).
    static func demoHistory(now: Date = Date()) -> [HistoryEntry] {
        let rules = ["xcode-derived-data", "ae-disk-cache", "huggingface", "user-caches", "downloads", "simulators-data"]
        let plan: [(days: Int, gb: Double)] = [(28, 12.4), (24, 3.1), (21, 46.0), (17, 1.2), (14, 8.8), (12, 0.6), (9, 24.0),
                                               (7, 2.3), (5, 10.5), (3, 5.2), (2, 1.1), (0, 18.7)]
        return plan.enumerated().map { i, p in
            HistoryEntry(date: now.addingTimeInterval(-Double(p.days) * 86_400), ruleID: rules[i % rules.count],
                         bytes: Int64(p.gb * 1e9), itemCount: 10 + i * 3, method: .delete)
        }
    }

    @MainActor
    static func write(_ view: some View, to url: URL, size: CGSize? = ScreenSnapshots.size) throws {
        let content = view
            .frame(width: size?.width, height: size?.height)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshot, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let cg = renderer.cgImage else { throw GallerySnapshot.Failure.render }
        guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw GallerySnapshot.Failure.encode
        }
        try data.write(to: url)
    }
}
