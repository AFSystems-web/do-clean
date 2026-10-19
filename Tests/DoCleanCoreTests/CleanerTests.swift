import XCTest
@testable import DoCleanCore

final class CleanerTests: XCTestCase {
    var fs: FakeFS!
    override func setUp() { fs = FakeFS() }

    /// AE cache (green/delete, children) + a yellow rule that goes to the Trash, scanned on the fake FS.
    func scanned(running: Set<String> = [], runner: (any CommandRunner)? = nil, ids: [String]) async throws -> (DoCleanEnvironment, ScanResult) {
        let env = fs.env(running: running, runner: runner)
        let rules = try loadCatalog().filter { ids.contains($0.id) }
        return (env, await CleanScanner(environment: env).scan(rules: rules))
    }

    func testDryRunTouchesNothing() async throws {
        let a = fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 100_000)
        let (env, res) = try await scanned(ids: ["ae-disk-cache"])
        let report = await fs.cleaner(env).clean(res.requests(ruleIDs: ["ae-disk-cache"]))   // dryRun defaults to true
        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.entries.map(\.outcome), [.wouldRemove])
        XCTAssertGreaterThanOrEqual(report.freedBytes, 100_000)
        XCTAssertTrue(fs.exists(a))
    }

    func testGreenDeletesPermanently() async throws {
        let a = fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 100_000)
        let (env, res) = try await scanned(ids: ["ae-disk-cache"])
        let report = await fs.cleaner(env).clean(res.requests(ruleIDs: ["ae-disk-cache"]), dryRun: false)
        XCTAssertEqual(report.entries.map(\.outcome), [.removed])
        XCTAssertFalse(fs.exists(a))
        XCTAssertTrue(fs.exists(fs.path("Library/Caches/Adobe/After Effects")), "the root itself stays")
        XCTAssertEqual((try? fs.fm.contentsOfDirectory(atPath: fs.trash.path))?.count, 0, "delete does not use the Trash")
    }

    func testYellowAndRedGoToTrash() async throws {
        let m = fs.file(".cache/huggingface/hub/models--a--b/blobs/x", size: 100_000)
        let d = fs.file("Downloads/big.dmg", size: 100_000, ageDays: 40)
        let (env, res) = try await scanned(ids: ["huggingface", "downloads"])
        let report = await fs.cleaner(env).clean(res.requests(ruleIDs: ["huggingface", "downloads"]), dryRun: false)
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertTrue(report.entries.allSatisfy { $0.outcome == .removed && $0.method == .trash })
        XCTAssertFalse(fs.exists(m)); XCTAssertFalse(fs.exists(d))
        XCTAssertEqual((try fs.fm.contentsOfDirectory(atPath: fs.trash.path)).count, 2, "both ended up in the (fake) Trash")
    }

    func testTrashRuleEmptiesPermanently() async throws {
        let t = fs.file(".Trash/old.zip", size: 100_000)
        let (env, res) = try await scanned(ids: ["trash"])
        let report = await fs.cleaner(env).clean(res.requests(ruleIDs: ["trash"]), dryRun: false)
        XCTAssertEqual(report.entries.first?.method, .delete)
        XCTAssertFalse(fs.exists(t))
    }

    func testModifiedAfterScanIsSkipped() async throws {
        let a = fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 100_000)
        let (env, res) = try await scanned(ids: ["ae-disk-cache"])
        fs.touch(a)                                              // an app wrote to it after the scan
        let report = await fs.cleaner(env).clean(res.requests(ruleIDs: ["ae-disk-cache"]), dryRun: false)
        guard case .skipped(let why) = report.entries[0].outcome else { return XCTFail("\(report.entries[0].outcome)") }
        XCTAssertTrue(why.contains("changed after the scan"), why)
        XCTAssertTrue(fs.exists(a))
        XCTAssertEqual(report.freedBytes, 0)
    }

    func testNewFileAddedAfterScanIsAlsoDetected() async throws {
        fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 100_000)
        let (env, res) = try await scanned(ids: ["ae-disk-cache"])
        let newFile = fs.file("Library/Caches/Adobe/After Effects/26.0/new.bin", ageDays: 0)
        let report = await fs.cleaner(env).clean(res.requests(ruleIDs: ["ae-disk-cache"]), dryRun: false)
        if case .skipped = report.entries[0].outcome {} else { XCTFail("must skip") }
        XCTAssertTrue(fs.exists(newFile))
    }

    func testAppStartedAfterScanBlocksCleaning() async throws {
        let a = fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 100_000)
        let (_, res) = try await scanned(ids: ["ae-disk-cache"])
        let runningEnv = fs.env(running: ["com.adobe.AfterEffects"])
        let report = await fs.cleaner(runningEnv).clean(res.requests(ruleIDs: ["ae-disk-cache"]), dryRun: false)
        guard case .skipped(let why) = report.entries[0].outcome else { return XCTFail() }
        XCTAssertTrue(why.contains("app running"))
        XCTAssertTrue(fs.exists(a))
    }

    func testSymlinkEscapeNeverFollowed() async throws {
        let secret = fs.file("Documents/thesis.docx", size: 50_000)
        fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 100_000)
        let link = fs.path("Library/Caches/Adobe/After Effects/evil")
        try fs.fm.createSymbolicLink(at: link, withDestinationURL: fs.path("Documents"))
        let (env, res) = try await scanned(ids: ["ae-disk-cache"])
        // The scanner ignores zero-size links; force the link in as if a stale/forged selection contained it.
        var reqs = res.requests(ruleIDs: ["ae-disk-cache"])
        reqs[0].items.append(ScanItem(id: link.path, name: "evil", path: link.path, bytes: 1, fingerprint: Date.distantPast))
        let report = await fs.cleaner(env).clean(reqs, dryRun: false)
        XCTAssertTrue(fs.exists(secret), "the target of the symlink must survive")
        XCTAssertTrue(fs.exists(fs.path("Documents")))
        let evil = try XCTUnwrap(report.entries.first { $0.item.name == "evil" })
        if case .skipped = evil.outcome {} else { XCTFail("symlink escape must be skipped, got \(evil.outcome)") }
    }

    func testForgedItemOutsideRootIsRefused() async throws {
        let doc = fs.file("Documents/thesis.docx", size: 50_000)
        let ae = try rule("ae-disk-cache")
        let forged = ScanItem(id: doc.path, name: "thesis.docx", path: doc.path, bytes: 50_000, fingerprint: Date())
        let report = await fs.cleaner(fs.env()).clean([CleanRequest(rule: ae, items: [forged])], dryRun: false)
        if case .skipped = report.entries[0].outcome {} else { XCTFail("\(report.entries[0].outcome)") }
        XCTAssertTrue(fs.exists(doc))
    }

    func testItemWithoutFingerprintIsRefused() async throws {
        let a = fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin")
        let item = ScanItem(id: a.path, name: "a", path: a.path, bytes: 1, fingerprint: nil)
        let report = await fs.cleaner(fs.env()).clean([CleanRequest(rule: try rule("ae-disk-cache"), items: [item])], dryRun: false)
        if case .skipped = report.entries[0].outcome {} else { XCTFail() }
        XCTAssertTrue(fs.exists(a))
    }

    func testPartialFailureDoesNotStopTheRest() async throws {
        fs.file(".cache/huggingface/hub/models--a--one/blobs/x", size: 100_000)
        fs.file(".cache/huggingface/hub/models--a--two/blobs/x", size: 100_000)
        fs.file(".cache/huggingface/hub/models--a--three/blobs/x", size: 100_000)
        let (env, res) = try await scanned(ids: ["huggingface"])
        let report = await fs.cleaner(env, failing: ["models--a--two"]).clean(res.requests(ruleIDs: ["huggingface"]), dryRun: false)
        XCTAssertEqual(report.entries.count, 3)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(report.entries.filter { $0.outcome == .removed }.count, 2)
        XCTAssertTrue(fs.exists(fs.path(".cache/huggingface/hub/models--a--two")))
        XCTAssertGreaterThanOrEqual(report.freedBytes, 200_000)
    }

    func testCommandItemsRunOnlyAllowListedCommands() async throws {
        var runner = FakeRunner(installed: ["brew"])
        runner.outputs["cleanup -n --prune=all"] = CommandOutput(status: 0, stdout: "approximately 10MB of disk space")
        let (env, res) = try await scanned(runner: runner, ids: ["homebrew-cleanup"])
        let cleaner = fs.cleaner(env)
        let dry = await cleaner.clean(res.requests(ruleIDs: ["homebrew-cleanup"]))
        XCTAssertEqual(dry.entries.first?.outcome, .wouldRemove)
        XCTAssertFalse(runner.log.all.contains { $0.contains("--prune=all") && !$0.contains("-n") }, "dry run must not execute the real command")
        let real = await cleaner.clean(res.requests(ruleIDs: ["homebrew-cleanup"]), dryRun: false)
        XCTAssertEqual(real.entries.first?.outcome, .removed)
        XCTAssertTrue(runner.log.all.contains(["/fake/brew", "cleanup", "--prune=all"]))

        // a tampered catalog entry is refused
        var evil = try rule("homebrew-cleanup"); evil.command = ["brew", "uninstall", "--force", "git"]
        let item = ScanItem(id: "cmd:x", name: "x", path: nil, bytes: 1)
        let bad = await cleaner.clean([CleanRequest(rule: evil, items: [item])], dryRun: false)
        if case .skipped(let why) = bad.entries[0].outcome { XCTAssertTrue(why.contains("not allowed")) } else { XCTFail() }
        XCTAssertFalse(runner.log.all.contains { $0.contains("uninstall") })
    }

    func testFailedCommandIsReported() async throws {
        var runner = FakeRunner(installed: ["brew"])
        runner.outputs["cleanup -n --prune=all"] = CommandOutput(status: 0, stdout: "approximately 10MB of disk space")
        runner.outputs["cleanup --prune=all"] = CommandOutput(status: 1, stdout: "")
        let (env, res) = try await scanned(runner: runner, ids: ["homebrew-cleanup"])
        let report = await fs.cleaner(env).clean(res.requests(ruleIDs: ["homebrew-cleanup"]), dryRun: false)
        XCTAssertEqual(report.failed.count, 1)
    }

    func testBlockedRulesAreNotInRequests() async throws {
        fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin")
        let (_, res) = try await scanned(running: ["com.adobe.AfterEffects"], ids: ["ae-disk-cache"])
        XCTAssertTrue(res.requests(ruleIDs: ["ae-disk-cache"]).isEmpty)
    }

    func testHistoryRecordedOnRealRunOnly() async throws {
        fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 100_000)
        let history = History(fileURL: fs.root.appendingPathComponent("hist/history.json"))
        let (env, res) = try await scanned(ids: ["ae-disk-cache"])
        let cleaner = fs.cleaner(env, history: history)
        _ = await cleaner.clean(res.requests(ruleIDs: ["ae-disk-cache"]))
        XCTAssertTrue(history.entries().isEmpty, "dry run is not history")
        let report = await cleaner.clean(res.requests(ruleIDs: ["ae-disk-cache"]), dryRun: false)
        XCTAssertEqual(history.entries().count, 1)
        XCTAssertEqual(history.entries()[0].ruleID, "ae-disk-cache")
        XCTAssertEqual(history.totalFreed, report.freedBytes)
    }
}

final class HistoryTests: XCTestCase {
    func testAppendPersistAndTotals() throws {
        let fs = FakeFS()
        let url = fs.root.appendingPathComponent("a/b/history.json")
        let h = History(fileURL: url)
        XCTAssertEqual(h.totalFreed, 0)
        let day1 = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400 * 3 + 3600)
        try h.append([HistoryEntry(date: day1, ruleID: "a", bytes: 100, itemCount: 1, method: .delete),
                      HistoryEntry(date: day1.addingTimeInterval(60), ruleID: "b", bytes: 50, itemCount: 2, method: .trash)])
        try h.append([HistoryEntry(date: Date(), ruleID: "a", bytes: 25, itemCount: 1, method: .delete)])
        let reopened = History(fileURL: url)           // new instance reads the file
        XCTAssertEqual(reopened.entries().count, 3)
        XCTAssertEqual(reopened.totalFreed, 175)
        let days = reopened.freedByDay()
        XCTAssertEqual(days.count, 2); XCTAssertEqual(days[0].bytes, 150); XCTAssertEqual(days[1].bytes, 25)
    }

    func testCorruptFileIsTreatedAsEmpty() throws {
        let fs = FakeFS()
        let url = fs.root.appendingPathComponent("history.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let h = History(fileURL: url)
        XCTAssertEqual(h.entries().count, 0)
        try h.append([HistoryEntry(date: Date(), ruleID: "a", bytes: 1, itemCount: 1, method: .delete)])
        XCTAssertEqual(h.entries().count, 1)
    }

    func testDefaultLocation() {
        let home = URL(fileURLWithPath: "/h")
        XCTAssertEqual(History.defaultURL(home: home).path, "/h/Library/Application Support/do clean/history.json")
    }
}
