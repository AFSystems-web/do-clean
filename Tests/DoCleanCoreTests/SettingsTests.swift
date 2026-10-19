import XCTest
@testable import DoCleanCore

final class SettingsTests: XCTestCase {
    var fs: FakeFS!
    override func setUp() { fs = FakeFS() }

    func testDefaults() {
        let s = AppSettings()
        XCTAssertEqual(s.reminderDays, 7); XCTAssertEqual(s.largeFileThreshold, 500_000_000)
        XCTAssertEqual(s.greenMethod, .delete); XCTAssertEqual(s.language, .ru); XCTAssertTrue(s.excludedPaths.isEmpty)
    }

    func testRoundTripAndCorruptFile() throws {
        let store = SettingsStore(fileURL: fs.root.appendingPathComponent("x/settings.json"))
        XCTAssertEqual(store.load(), AppSettings())
        var s = AppSettings(); s.excludedPaths = ["~/Keep"]; s.excludedRuleIDs = ["huggingface"]; s.reminderDays = 14
        s.largeFileThreshold = 1_000_000_000; s.greenMethod = .trash; s.language = .en; s.firstLaunchAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.save(s)
        XCTAssertEqual(SettingsStore(fileURL: store.fileURL).load(), s)
        try "{garbage".write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), AppSettings())
    }

    func testTolerantDecoding() throws {
        let json = #"{"reminderDays":-5,"greenMethod":"command","language":"xx","largeFileThreshold":5,"future":1,"excludedPaths":["/a"]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.reminderDays, 0); XCTAssertEqual(s.greenMethod, .delete); XCTAssertEqual(s.language, .ru)
        XCTAssertEqual(s.largeFileThreshold, 1_000_000); XCTAssertEqual(s.excludedPaths, ["/a"])
    }

    @MainActor func testModelSavesAndStampsFirstLaunch() throws {
        let store = SettingsStore(fileURL: fs.root.appendingPathComponent("s.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let m = SettingsModel(store: store, now: now)
        XCTAssertEqual(m.settings.firstLaunchAt, now)
        m.exclude(path: "~/Keep"); m.exclude(path: "~/Keep"); m.setRule("trash", excluded: true)
        XCTAssertEqual(store.load().excludedPaths, ["~/Keep"]); XCTAssertEqual(store.load().excludedRuleIDs, ["trash"])
        m.setRule("trash", excluded: false); m.include(path: "~/Keep")
        XCTAssertEqual(store.load().excludedPaths, []); XCTAssertEqual(store.load().excludedRuleIDs, [])
        XCTAssertEqual(SettingsModel(store: store, now: Date()).settings.firstLaunchAt, now, "first launch is stamped once")
    }

    // MARK: exclusions are enforced

    func testExcludedRuleIsNotScanned() async throws {
        fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 100_000)
        var s = AppSettings(); s.excludedRuleIDs = ["ae-disk-cache"]
        let env = fs.env().applying(s)
        let res = await CleanScanner(environment: env).scan(rules: try loadCatalog().filter { $0.id == "ae-disk-cache" || $0.id == "user-caches" })
        XCTAssertNil(res.result(id: "ae-disk-cache"))
        let direct = await CleanScanner(environment: env).scan(rule: try rule("ae-disk-cache"))
        XCTAssertEqual(direct.status, .empty); XCTAssertTrue(direct.items.isEmpty)
    }

    func testExcludedPathIsSkippedInScanAndItsParentToo() async throws {
        fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 100_000)
        fs.file("Library/Caches/Adobe/After Effects/26.5/a.bin", size: 100_000)
        var s = AppSettings(); s.excludedPaths = ["~/Library/Caches/Adobe/After Effects/26.5"]
        let r = await CleanScanner(environment: fs.env().applying(s)).scan(rule: try rule("ae-disk-cache"))
        XCTAssertEqual(r.items.map(\.name), ["26.0"])
        // a rule whose item would contain the excluded folder is dropped as a whole
        var s2 = AppSettings(); s2.excludedPaths = ["~/Library/Caches/Adobe/After Effects/26.5/a.bin"]
        let r2 = await CleanScanner(environment: fs.env().applying(s2)).scan(rule: try rule("ae-disk-cache"))
        XCTAssertEqual(r2.items.map(\.name), ["26.0"])
    }

    func testCleanerRefusesExcludedEvenWithStaleScan() async throws {
        let a = fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 100_000)
        let res = await CleanScanner(environment: fs.env()).scan(rules: [try rule("ae-disk-cache")])   // scanned BEFORE excluding
        var s = AppSettings(); s.excludedPaths = ["~/Library/Caches/Adobe"]
        let report = await fs.cleaner(fs.env().applying(s)).clean(res.requests(ruleIDs: ["ae-disk-cache"]), dryRun: false)
        guard case .skipped(let why) = report.entries[0].outcome else { return XCTFail() }
        XCTAssertTrue(why.contains("excluded"))
        XCTAssertTrue(fs.exists(a))
        var s3 = AppSettings(); s3.excludedRuleIDs = ["ae-disk-cache"]
        let r3 = await fs.cleaner(fs.env().applying(s3)).clean(res.requests(ruleIDs: ["ae-disk-cache"]), dryRun: false)
        XCTAssertTrue(fs.exists(a)); XCTAssertEqual(r3.freedBytes, 0)
    }

    func testToolsHonourExclusions() async throws {
        fs.file("Movies/keep/film.mov", size: 3_000_000); fs.file("Movies/other.mov", size: 2_000_000)
        fs.file("Documents/a/dup.bin", size: 300_000); fs.file("Documents/b/dup.bin", size: 300_000); fs.file("Desktop/dup.bin", size: 300_000)
        fs.file("Downloads/skipme.dmg", size: 100); fs.file("Downloads/other.dmg", size: 100)
        var s = AppSettings(); s.excludedPaths = ["~/Movies/keep", "~/Documents/b", "~/Downloads/skipme.dmg"]; s.largeFileThreshold = 1_000_000
        let env = fs.env().applying(s)
        let large = await LargeFilesFinder(environment: env, settings: s, dates: NoFileDates()).find()
        XCTAssertEqual(large.map(\.name), ["other.mov"])
        let groups = await DuplicateFinder(environment: env, minBytes: 100_000, dates: NoFileDates()).find()
        let paths = groups.first?.files.map(\.path) ?? []
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.contains { $0.hasSuffix("/home/Documents/a/dup.bin") } && paths.contains { $0.hasSuffix("/home/Desktop/dup.bin") })
        let dl = await DownloadsTool(environment: env, dates: NoFileDates()).list()
        XCTAssertEqual(dl.map(\.file.name), ["other.dmg"])
    }

    // MARK: green method

    func testGreenMethodTrashSendsGreenToTrash() async throws {
        let a = fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 100_000)
        let res = await CleanScanner(environment: fs.env()).scan(rules: [try rule("ae-disk-cache")])
        var s = AppSettings(); s.greenMethod = .trash
        let cleaner = Cleaner(environment: fs.env(), settings: s, trasher: FakeTrasher(trash: fs.trash))
        let report = await cleaner.clean(res.requests(ruleIDs: ["ae-disk-cache"]), dryRun: false)
        XCTAssertEqual(report.entries.first?.method, .trash); XCTAssertEqual(report.entries.first?.outcome, .removed)
        XCTAssertFalse(fs.exists(a)); XCTAssertEqual(try fs.fm.contentsOfDirectory(atPath: fs.trash.path).count, 1)
    }

    func testGreenMethodDoesNotTouchCommandRules() async throws {
        var runner = FakeRunner(installed: ["brew"])
        runner.outputs["cleanup -n --prune=all"] = CommandOutput(status: 0, stdout: "approximately 10MB")
        let env = fs.env(runner: runner)
        let res = await CleanScanner(environment: env).scan(rules: [try rule("homebrew-cleanup")])
        var s = AppSettings(); s.greenMethod = .trash
        let report = await Cleaner(environment: env, settings: s, trasher: FakeTrasher(trash: fs.trash)).clean(res.requests(ruleIDs: ["homebrew-cleanup"]))
        XCTAssertEqual(report.entries.first?.method, .command)
    }

    func testLargeThresholdFromSettings() async throws {
        fs.file("Movies/a.mov", size: 2_000_000)
        var s = AppSettings(); s.largeFileThreshold = 3_000_000
        let none = await LargeFilesFinder(environment: fs.env(), settings: s, dates: NoFileDates()).find()
        XCTAssertTrue(none.isEmpty)
        s.largeFileThreshold = 1_000_000
        let one = await LargeFilesFinder(environment: fs.env(), settings: s, dates: NoFileDates()).find()
        XCTAssertEqual(one.count, 1)
    }
}

final class FullDiskAccessTests: XCTestCase {
    func testGrantedDeniedUnknown() throws {
        let fs = FakeFS()
        let readable = fs.file("ok.plist", size: 10)
        XCTAssertEqual(FullDiskAccessProbe(candidates: [readable.path]).check(), .granted)
        XCTAssertEqual(FullDiskAccessProbe(candidates: [fs.path("missing").path]).check(), .unknown)
        XCTAssertEqual(FullDiskAccessProbe(candidates: []).check(), .unknown)
        XCTAssertEqual(FullDiskAccessProbe(candidates: [fs.path("missing").path, readable.path]).check(), .granted, "first missing path is skipped")
        let locked = fs.file("locked.plist", size: 10)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        if geteuid() != 0 {
            XCTAssertEqual(FullDiskAccessProbe(candidates: [locked.path]).check(), .denied)
            XCTAssertEqual(FullDiskAccessProbe(candidates: [fs.path("missing").path, locked.path]).check(), .denied)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
    }

    func testRealProbeReturnsSomething() {
        _ = FullDiskAccessProbe().check()   // must not crash on the real machine
        XCTAssertEqual(FullDiskAccessProbe.settingsURL.scheme, "x-apple.systempreferences")
    }
}

final class HistoryStatsTests: XCTestCase {
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 2; return c }()
    func d(_ s: String) -> Date { let f = ISO8601DateFormatter(); return f.date(from: s)! }

    func stats() throws -> HistoryStats {
        func e(_ date: String, _ rule: String, _ bytes: Int64) -> HistoryEntry { HistoryEntry(date: d(date), ruleID: rule, bytes: bytes, itemCount: 1, method: .delete) }
        return HistoryStats(entries: [e("2026-10-19T09:00:00Z", "ae-disk-cache", 100), e("2026-10-19T18:00:00Z", "huggingface", 50),
                                      e("2026-10-14T12:00:00Z", "xcode-derived-data", 30), e("2026-09-01T12:00:00Z", "tool-duplicates", 7),
                                      e("2026-10-01T12:00:00Z", "gone-rule", 3)],
                            rules: try loadCatalog(), calendar: cal)
    }

    func testTotalsAndCategories() throws {
        let s = try stats()
        XCTAssertEqual(s.totalFreed, 190); XCTAssertEqual(s.cleanupCount, 5)
        XCTAssertEqual(s.lastCleanup, d("2026-10-19T18:00:00Z")); XCTAssertEqual(s.biggest?.bytes, 100)
        let c = s.byCategory()
        XCTAssertEqual(c[.creative], 100); XCTAssertEqual(c[.ai], 50); XCTAssertEqual(c[.dev], 30)
        XCTAssertEqual(c[.personal], 7, "tool entries are personal"); XCTAssertEqual(c[.system], 3, "unknown rule falls back to system")
        XCTAssertEqual(s.byRule().first?.ruleID, "ae-disk-cache")
    }

    func testPerDayIsZeroFilled() throws {
        let days = try stats().perDay(last: 7, now: d("2026-10-19T20:00:00Z"))
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.last?.bytes, 150); XCTAssertEqual(days.last?.start, d("2026-10-19T00:00:00Z"))
        XCTAssertEqual(days.first?.start, d("2026-10-13T00:00:00Z"))
        XCTAssertEqual(days.first { $0.start == d("2026-10-14T00:00:00Z") }?.bytes, 30)
        XCTAssertEqual(days.filter { $0.bytes == 0 }.count, 5)
    }

    func testPerWeek() throws {
        let weeks = try stats().perWeek(last: 4, now: d("2026-10-19T20:00:00Z"))   // Monday 19 Oct
        XCTAssertEqual(weeks.count, 4)
        XCTAssertEqual(weeks.last?.bytes, 150, "this week starts Monday 19 Oct")
        XCTAssertEqual(weeks[2].bytes, 30, "week of 12 Oct holds the 14th")
        XCTAssertEqual(weeks.reduce(0) { $0 + $1.bytes }, 183 - 0, "01 Oct entry falls in the week of 28 Sep: 150+30+3")
    }

    func testFreedSinceAndEmpty() throws {
        XCTAssertEqual(try stats().freed(since: d("2026-10-15T00:00:00Z")), 150)
        let empty = HistoryStats(entries: [], rules: [], calendar: cal)
        XCTAssertEqual(empty.totalFreed, 0); XCTAssertNil(empty.lastCleanup); XCTAssertEqual(empty.perDay(last: 3).count, 3)
    }
}

final class ReminderSchedulerTests: XCTestCase {
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    var sched: ReminderScheduler { ReminderScheduler(calendar: cal, hour: 10) }

    func testOffWhenZero() {
        var s = AppSettings(); s.reminderDays = 0
        XCTAssertNil(sched.nextReminder(settings: s, lastCleanup: nil))
        XCTAssertFalse(sched.isDue(settings: s, lastCleanup: nil))
    }

    func testDueSevenDaysAfterLastCleanup() {
        var s = AppSettings(); s.reminderDays = 7; s.firstLaunchAt = d("2026-01-01T00:00:00Z")
        let last = d("2026-10-10T15:30:00Z")
        XCTAssertEqual(sched.nextReminder(settings: s, lastCleanup: last, now: d("2026-10-12T00:00:00Z")), d("2026-10-17T10:00:00Z"))
        XCTAssertFalse(sched.isDue(settings: s, lastCleanup: last, now: d("2026-10-17T09:00:00Z")))
        XCTAssertTrue(sched.isDue(settings: s, lastCleanup: last, now: d("2026-10-17T10:00:00Z")))
    }

    func testCountsFromFirstLaunchWithoutCleanups() {
        var s = AppSettings(); s.reminderDays = 3; s.firstLaunchAt = d("2026-10-01T08:00:00Z")
        XCTAssertEqual(sched.nextReminder(settings: s, lastCleanup: nil, now: d("2026-10-02T00:00:00Z")), d("2026-10-04T10:00:00Z"))
    }

    func testOverdueRollsToNextTenOClock() {
        var s = AppSettings(); s.reminderDays = 7; s.firstLaunchAt = d("2026-01-01T00:00:00Z")
        let last = d("2026-09-01T12:00:00Z")
        XCTAssertTrue(sched.isDue(settings: s, lastCleanup: last, now: d("2026-10-19T12:00:00Z")))
        XCTAssertEqual(sched.nextReminder(settings: s, lastCleanup: last, now: d("2026-10-19T12:00:00Z")), d("2026-10-20T10:00:00Z"))
        XCTAssertEqual(sched.nextReminder(settings: s, lastCleanup: last, now: d("2026-10-19T08:00:00Z")), d("2026-10-19T10:00:00Z"))
    }

    func testLastReminderDelaysNextOne() {
        var s = AppSettings(); s.reminderDays = 7; s.firstLaunchAt = d("2026-01-01T00:00:00Z")
        s.lastReminderAt = d("2026-10-19T10:00:00Z")
        let last = d("2026-09-01T12:00:00Z")
        XCTAssertFalse(sched.isDue(settings: s, lastCleanup: last, now: d("2026-10-20T12:00:00Z")))
        XCTAssertEqual(sched.nextReminder(settings: s, lastCleanup: last, now: d("2026-10-20T12:00:00Z")), d("2026-10-26T10:00:00Z"))
    }
}
