import XCTest
@testable import DoCleanCore

struct ScriptedDates: FileDateProvider {
    var opened: [String: Date] = [:]
    var added: [String: Date] = [:]
    func lastOpened(_ url: URL) -> Date? { opened[url.lastPathComponent] }
    func dateAdded(_ url: URL) -> Date? { added[url.lastPathComponent] }
}

final class ToolsTests: XCTestCase {
    var fs: FakeFS!
    override func setUp() { fs = FakeFS() }
    func days(_ d: Double) -> Date { Date().addingTimeInterval(-d * 86_400) }

    // MARK: personal rules

    func testPersonalRulesAreMergedByPriority() throws {
        let bundled = try loadCatalog()
        let folder = fs.root.appendingPathComponent("personal-rules", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var mine = try XCTUnwrap(bundled.first { $0.id == "user-caches" })
        mine.id = "personal-test"; mine.priority = 1
        try JSONEncoder().encode([mine]).write(to: folder.appendingPathComponent("mine.json"))
        let merged = try RuleCatalog.loadWithUserRules(userFolder: folder)
        XCTAssertEqual(merged.count, bundled.count + 1)
        XCTAssertEqual(merged.first?.id, "personal-test", "lowest priority number goes first and owns its paths")
    }

    func testPersonalRuleCannotReplaceBundledID() throws {
        let folder = fs.root.appendingPathComponent("personal-rules", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clone = try XCTUnwrap(try loadCatalog().first { $0.id == "user-caches" })
        try JSONEncoder().encode([clone]).write(to: folder.appendingPathComponent("clash.json"))
        XCTAssertThrowsError(try RuleCatalog.loadWithUserRules(userFolder: folder))
    }

    func testMissingPersonalFolderIsFine() throws {
        let merged = try RuleCatalog.loadWithUserRules(userFolder: fs.root.appendingPathComponent("nope"))
        XCTAssertEqual(merged.count, try loadCatalog().count)
    }

    // MARK: large files

    func testLargeFilesFindsAllowedFoldersAndSkipsTheRest() async throws {
        fs.file("Movies/film.mov", size: 3_000_000)
        fs.file("Documents/big.psd", size: 2_000_000)
        fs.file("Desktop/render.mp4", size: 1_500_000)
        fs.file("Pictures/Photos Library.photoslibrary/originals/a.heic", size: 4_000_000)   // package
        fs.file("Library/Application Support/X/huge.db", size: 5_000_000)
        fs.file("Library/Mobile Documents/com~apple~CloudDocs/x.bin", size: 5_000_000)
        fs.file(".hidden/huge.bin", size: 5_000_000)
        fs.file("proj/node_modules/x/huge.bin", size: 5_000_000)
        fs.file("small.bin", size: 100_000)
        let dates = ScriptedDates(opened: ["film.mov": days(3)])
        let found = await LargeFilesFinder(environment: fs.env(), minBytes: 1_000_000, dates: dates).find()
        XCTAssertEqual(found.map(\.name), ["film.mov", "big.psd", "render.mp4"], "biggest first, nothing from forbidden/hidden/package areas")
        XCTAssertNotNil(found[0].lastOpened)
        XCTAssertGreaterThanOrEqual(found[0].bytes, 3_000_000)
    }

    func testIcloudPlaceholdersAreIgnored() async throws {
        fs.file("Documents/.big.bin.icloud", size: 3_000_000)
        let found = await LargeFilesFinder(environment: fs.env(), minBytes: 1_000_000, dates: NoFileDates()).find()
        XCTAssertTrue(found.isEmpty)
    }

    func testLargeFilesGoToTrashViaCleaner() async throws {
        let f = fs.file("Documents/big.psd", size: 2_000_000)
        let keep = fs.file("Documents/keep.txt", size: 10)
        let finder = LargeFilesFinder(environment: fs.env(), minBytes: 1_000_000, dates: NoFileDates())
        let found = await finder.find()
        let req = finder.cleanRequest(found)
        let cleaner = fs.cleaner(fs.env())
        let dry = await cleaner.clean([req])
        XCTAssertEqual(dry.entries.map(\.outcome), [.wouldRemove]); XCTAssertTrue(fs.exists(f))
        let real = await cleaner.clean([req], dryRun: false)
        XCTAssertEqual(real.entries.first?.method, .trash)
        XCTAssertFalse(fs.exists(f)); XCTAssertTrue(fs.exists(keep))
        XCTAssertEqual(try fs.fm.contentsOfDirectory(atPath: fs.trash.path).count, 1)
    }

    func testToolModeDoesNotUnlockDocumentsForNormalRequests() async throws {
        let f = fs.file("Documents/big.psd", size: 2_000_000)
        let item = ScanItem(id: f.path, name: "big.psd", path: f.path, bytes: 1, fingerprint: Date.distantPast.addingTimeInterval(1e9))
        // Same item, but a catalog-style request (no allowUserFolders) must be refused.
        let req = CleanRequest(rule: try rule("downloads"), items: [item])
        let report = await fs.cleaner(fs.env()).clean([req], dryRun: false)
        if case .skipped = report.entries[0].outcome {} else { XCTFail("\(report.entries[0].outcome)") }
        XCTAssertTrue(fs.exists(f))
        // …and tool mode never unlocks Keychains / Application Support / photos libraries.
        let g = SafetyGuard(home: fs.home).relaxedForTools()
        for p in ["Library/Keychains/login.keychain-db", "Library/Application Support/x", "Pictures/Photos Library.photoslibrary/a", ".ssh/id_rsa"] {
            XCTAssertThrowsError(try g.checkPath(fs.path(p)), p)
        }
        XCTAssertNoThrow(try g.checkPath(fs.path("Documents/a.txt")))
    }

    func testToolRequestWithDeleteMethodIsRefused() async throws {
        let f = fs.file("Documents/big.psd", size: 2_000_000)
        var rule = ToolCleanup.rule(id: "x", title: L10n(ru: "x", en: "x")); rule.deletion = .delete
        let item = ScanItem(id: f.path, name: "big.psd", path: f.path, bytes: 1, fingerprint: try XCTUnwrap(try f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
        let report = await fs.cleaner(fs.env()).clean([CleanRequest(rule: rule, items: [item], allowUserFolders: true)], dryRun: false)
        if case .skipped = report.entries[0].outcome {} else { XCTFail() }
        XCTAssertTrue(fs.exists(f))
    }

    // MARK: old files

    func testOldFilesNeedAgeSizeAndNoRecentOpen() async throws {
        fs.file("Documents/old.zip", size: 2_000_000, ageDays: 500)
        fs.file("Documents/old-but-opened.zip", size: 2_000_000, ageDays: 500)
        fs.file("Documents/recent.zip", size: 2_000_000, ageDays: 20)
        fs.file("Documents/tiny-old.txt", size: 100, ageDays: 900)
        fs.file("Documents/oldest.zip", size: 2_000_000, ageDays: 800)
        let dates = ScriptedDates(opened: ["old-but-opened.zip": days(10)])
        let found = await OldFilesFinder(environment: fs.env(), minBytes: 1_000_000, dates: dates).find()
        XCTAssertEqual(found.map(\.name), ["oldest.zip", "old.zip"], "oldest first; opened/recent/small excluded")
    }

    // MARK: duplicates

    func testDuplicatesGroupedBySha256() async throws {
        func write(_ rel: String, _ bytes: [UInt8], age: Double = 10) -> URL {
            let u = fs.path(rel); try! fs.fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(bytes).write(to: u); try! fs.fm.setAttributes([.modificationDate: days(age)], ofItemAtPath: u.path); return u
        }
        let big = [UInt8](repeating: 7, count: 300_000)
        var sameHeadTail = big; sameHeadTail[150_000] = 9        // same size, same first/last 64 KB, different middle
        _ = write("Downloads/a.bin", big, age: 1)
        _ = write("Documents/a-original.bin", big, age: 100)
        _ = write("Desktop/a-copy.bin", big, age: 50)
        _ = write("Documents/middle-differs.bin", sameHeadTail)
        _ = write("Documents/unique.bin", [UInt8](repeating: 1, count: 400_000))
        _ = write("Documents/small-dupe1.bin", [1, 2, 3]); _ = write("Desktop/small-dupe2.bin", [1, 2, 3])
        let groups = await DuplicateFinder(environment: fs.env(), minBytes: 100_000, dates: NoFileDates()).find()
        XCTAssertEqual(groups.count, 1, "different-middle file must not join; small files are below the threshold")
        let g = groups[0]
        XCTAssertEqual(Set(g.files.map(\.name)), ["a.bin", "a-original.bin", "a-copy.bin"])
        XCTAssertEqual(g.keep.name, "a-original.bin", "oldest copy outside Downloads")
        XCTAssertEqual(g.removable.count, 2)
        XCTAssertEqual(g.reclaimableBytes, g.removable.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(g.sha256.count, 64)
    }

    func testKeepPrefersOutsideDownloadsThenOldest() {
        let home = URL(fileURLWithPath: "/h")
        func f(_ p: String, _ age: Double) -> ToolFile { ToolFile(path: p, name: p, bytes: 1, modified: Date().addingTimeInterval(-age * 86_400)) }
        XCTAssertEqual(DuplicateFinder.suggestKeep([f("/h/Downloads/a", 900), f("/h/Documents/b", 5)], home: home), 1)
        XCTAssertEqual(DuplicateFinder.suggestKeep([f("/h/Downloads/a", 900), f("/h/Downloads/b", 5)], home: home), 0)
        XCTAssertEqual(DuplicateFinder.suggestKeep([f("/h/Documents/a", 1), f("/h/Desktop/b", 50)], home: home), 1)
    }

    func testHardLinksAreNotDuplicates() async throws {
        let a = fs.file("Documents/a.bin", size: 300_000)
        try fs.fm.linkItem(at: a, to: fs.path("Documents/b.bin"))
        let groups = await DuplicateFinder(environment: fs.env(), minBytes: 100_000, dates: NoFileDates()).find()
        XCTAssertTrue(groups.isEmpty)
    }

    func testDuplicateCleanupNeverRemovesEveryCopy() async throws {
        let bytes = [UInt8](repeating: 3, count: 200_000)
        for rel in ["Documents/a.bin", "Desktop/b.bin", "Downloads/c.bin"] {
            let u = fs.path(rel); try fs.fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: u); try fs.fm.setAttributes([.modificationDate: days(10)], ofItemAtPath: u.path)
        }
        let groups = await DuplicateFinder(environment: fs.env(), minBytes: 100_000, dates: NoFileDates()).find()
        let g = try XCTUnwrap(groups.first)
        // Even if the UI passes every file, the kept one is dropped from the request.
        let req = g.cleanRequest(removing: g.files)
        XCTAssertEqual(req.items.count, 2)
        XCTAssertFalse(req.items.contains { $0.path == g.keep.path })
        let report = await fs.cleaner(fs.env()).clean([req], dryRun: false) 
        XCTAssertEqual(report.entries.filter { $0.outcome == .removed }.count, 2)
        XCTAssertTrue(fs.exists(g.keep.url))
    }

    func testDuplicateSearchCancellation() async throws {
        for i in 0..<6 { fs.file("Documents/d\(i).bin", size: 200_000) }
        let env = fs.env()
        let t = Task { await DuplicateFinder(environment: env, minBytes: 100_000, dates: NoFileDates()).find() }
        t.cancel()
        let groups = await t.value
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: downloads

    func testDownloadsFilters() async throws {
        fs.file("Downloads/new.txt", size: 100, ageDays: 2)
        fs.file("Downloads/old40.txt", size: 100, ageDays: 40)
        fs.file("Downloads/old100.txt", size: 100, ageDays: 100)
        fs.file("Downloads/App.dmg", size: 100, ageDays: 1)
        fs.file("Downloads/tool.pkg", size: 100, ageDays: 1)
        fs.file("Downloads/disk.iso", size: 100, ageDays: 1)
        fs.file("Downloads/photos.zip", size: 100, ageDays: 1)
        fs.file("Downloads/Foo-macOS-arm64.zip", size: 100, ageDays: 1)
        fs.file("Downloads/folder/inside.txt", size: 100, ageDays: 50)
        let zipWithApp = fs.path("Downloads/hasapp.zip")
        try Data("PK\u{3}\u{4}....Foo.app/Contents/Info.plist....".utf8).write(to: zipWithApp)
        try fs.fm.setAttributes([.modificationDate: days(1)], ofItemAtPath: zipWithApp.path)
        // opened recently => not "old", even though modified long ago
        fs.file("Downloads/reopened.txt", size: 100, ageDays: 200)
        let dates = ScriptedDates(opened: ["reopened.txt": days(3)], added: ["old40.txt": days(45)])
        let tool = DownloadsTool(environment: fs.env(), dates: dates)
        let all = await tool.find(.all)
        XCTAssertEqual(all.count, 11)
        let o30 = await tool.find(.olderThan(days: 30)), o90 = await tool.find(.olderThan(days: 90)), inst = await tool.find(.installers)
        XCTAssertEqual(Set(o30.map(\.file.name)), ["old40.txt", "old100.txt", "folder"])
        XCTAssertEqual(Set(o90.map(\.file.name)), ["old100.txt"])
        XCTAssertEqual(Set(inst.map(\.file.name)), ["App.dmg", "tool.pkg", "disk.iso", "Foo-macOS-arm64.zip", "hasapp.zip"])
        XCTAssertTrue(all.first { $0.file.name == "folder" }!.isDirectory)
    }

    func testDownloadsCleanupGoesToTrash() async throws {
        let f = fs.file("Downloads/old.dmg", size: 5000, ageDays: 100)
        let tool = DownloadsTool(environment: fs.env(), dates: NoFileDates())
        let items = await tool.find(.installers)
        let report = await fs.cleaner(fs.env(), failing: []).clean([tool.cleanRequest(items)], dryRun: false)
        XCTAssertEqual(report.entries.first?.method, .trash)
        XCTAssertFalse(fs.exists(f))
    }

    // MARK: node_modules

    func testNodeModulesFinderReportsProjectDate() async throws {
        fs.file("Developer/old/package.json", ageDays: 90)
        fs.file("Developer/old/node_modules/a/i.js", size: 50_000, ageDays: 90)
        fs.file("Developer/fresh/package.json", ageDays: 1)
        fs.file("Developer/fresh/node_modules/a/i.js", size: 50_000, ageDays: 1)
        let oldR = await NodeModulesFinder(environment: fs.env(), olderThanDays: 30).find()
        let old = try XCTUnwrap(oldR)
        XCTAssertEqual(old.projects.map(\.name), ["old"])
        XCTAssertLessThan(try XCTUnwrap(old.projects[0].projectLastModified), days(80))
        let allR = await NodeModulesFinder(environment: fs.env(), olderThanDays: 0).find()
        let all = try XCTUnwrap(allR)
        XCTAssertEqual(Set(all.projects.map(\.name)), ["old", "fresh"])
        XCTAssertEqual(all.request.rule.deletion, .trash)
    }

    // MARK: observable model

    @MainActor
    func testToolModelRuns() async throws {
        fs.file("Movies/film.mov", size: 3_000_000)
        let env = fs.env()
        let model = ToolModel<[ToolFile]>()
        model.run { progress in await LargeFilesFinder(environment: env, minBytes: 1_000_000, dates: NoFileDates()).find(progress: progress) }
        for _ in 0..<200 where model.phase == .running { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(model.output?.count, 1)
    }
}
