import XCTest
@testable import DoCleanCore

final class ScannerRulesTests: XCTestCase {
    var fs: FakeFS!
    override func setUp() { fs = FakeFS() }

    func scan(_ id: String, running: Set<String> = [], runner: (any CommandRunner)? = nil) async throws -> RuleResult {
        let env = fs.env(running: running, runner: runner)
        return await CleanScanner(environment: env).scan(rule: try rule(id))
    }

    /// A file name that matches a glob.
    func sample(_ pattern: String?) -> String { (pattern ?? "child").replacingOccurrences(of: "*", with: "x") }

    // MARK: every standard rule of the real catalog finds what it should on the fake FS

    func testEveryStandardRuleFindsItsFiles() async throws {
        let standard = try loadCatalog().filter { $0.kind == .standard }
        XCTAssertGreaterThan(standard.count, 25)
        for var r in standard {
            let fresh = FakeFS()
            let env = fresh.env()
            // Never write into the real /tmp: absolute roots are redirected into the fake tmp folder.
            r.roots = r.roots.map { $0.hasPrefix("/") ? fresh.tmp.path : $0 }
            for (i, rootStr) in r.roots.enumerated() {
                let root = env.expand(rootStr)
                let name = sample(r.patterns.first)
                switch r.itemMode {
                case .root: fresh.file("a.bin", size: 50_000, ageDays: 40, base: root)
                case .files: fresh.file(name, size: 50_000, ageDays: 40, base: root)
                case .children:
                    var rel = name + "\(i)"
                    for _ in 1..<max(1, r.childDepth) { rel = "pub/" + rel }
                    fresh.file(rel + "/data.bin", size: 50_000, ageDays: 40, base: root)
                }
            }
            let res = await CleanScanner(environment: env).scan(rule: r)
            XCTAssertEqual(res.status, .ready, "\(r.id): \(res.status) \(res.message ?? "")")
            XCTAssertGreaterThanOrEqual(res.bytes, 50_000 * Int64(r.roots.count), r.id)
            for item in res.items { XCTAssertNotNil(item.fingerprint, r.id) }
        }
    }

    func testEmptyWhenNothingThere() async throws {
        let r = try await scan("ae-disk-cache")
        XCTAssertEqual(r.status, .empty); XCTAssertEqual(r.bytes, 0)
    }

    // MARK: specific behaviours

    func testRealAllocatedSizeIsReported() async throws {
        fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 5_000_000)
        let r = try await scan("ae-disk-cache")
        XCTAssertGreaterThanOrEqual(r.bytes, 5_000_000)
        XCTAssertLessThan(r.bytes, 5_200_000)
    }

    func testRunningAppBlocksButStillReportsSize() async throws {
        fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 2_000_000)
        let r = try await scan("ae-disk-cache", running: ["com.adobe.AfterEffects"])
        XCTAssertEqual(r.status, .blockedByRunningApp)
        XCTAssertEqual(r.blockedBy, ["com.adobe.AfterEffects"])
        XCTAssertGreaterThanOrEqual(r.bytes, 2_000_000)
        XCTAssertFalse(r.isCleanable)
        // versioned bundle id matched by prefix
        let p = try await scan("ae-disk-cache", running: ["com.adobe.AfterEffects.26"])
        XCTAssertEqual(p.status, .blockedByRunningApp)
        // an unrelated app does not block
        let o = try await scan("ae-disk-cache", running: ["com.apple.Safari"])
        XCTAssertEqual(o.status, .ready)
    }

    func testUserCachesExcludesAppleAndYoungAndOwned() async throws {
        fs.file("Library/Caches/com.acme.app/c.bin", ageDays: 10)
        fs.file("Library/Caches/com.apple.Safari/c.bin", ageDays: 10)
        fs.file("Library/Caches/CloudKit/c.bin", ageDays: 10)
        fs.file("Library/Caches/Adobe/x.bin", ageDays: 10)
        fs.file("Library/Caches/fresh.app/c.bin", ageDays: 0)
        let r = try await scan("user-caches")
        XCTAssertEqual(r.items.map(\.name), ["com.acme.app"])
    }

    func testTempFilesOnlyOldAndNotSystem() async throws {
        fs.file("old/a.bin", ageDays: 5, base: fs.tmp)
        fs.file("new/a.bin", ageDays: 1, base: fs.tmp)
        fs.file("com.apple.foo/a.bin", ageDays: 9, base: fs.tmp)
        var env = fs.env(); env.tmpDir = fs.tmp
        let r = await CleanScanner(environment: env).scan(rule: try rule("temp-files"))
        XCTAssertEqual(r.items.map(\.name), ["old"])
    }

    func testBlenderTempRendersOnlyPatternAndAge() async throws {
        XCTAssertNoThrow(try fs.env(allowRealTmp: true).guardrail.checkRoot(URL(fileURLWithPath: "/tmp")))   // the real rule's root is allowed
        let rule = Rule(id: "t", title: L10n(ru: "т", en: "t"), whySafe: L10n(ru: "т", en: "t"), tier: .green, category: .creative,
                        roots: [fs.tmp.path], itemMode: .files, patterns: ["*.png", "*.exr"], minAgeDays: 1, recursive: false)
        fs.file("frame.png", ageDays: 3, base: fs.tmp); fs.file("a.exr", ageDays: 3, base: fs.tmp)
        fs.file("keep.txt", ageDays: 3, base: fs.tmp); fs.file("new.png", ageDays: 0, base: fs.tmp)
        fs.file("sub/deep.png", ageDays: 3, base: fs.tmp)
        let r = await CleanScanner(environment: fs.env()).scan(rule: rule)
        XCTAssertEqual(Set(r.items.map(\.name)), ["frame.png", "a.exr"])
    }

    func testDeviceSupportKeepsNewest() async throws {
        let base = "Library/Developer/Xcode/iOS DeviceSupport/"
        fs.file(base + "iPhone14,2 26.6.2 (23G90)/s.bin", size: 100_000)
        fs.file(base + "iPhone15,2 26.4 (23E246)/s.bin", size: 100_000)
        fs.file(base + "iPhone16,1 26.6 (23G71)/s.bin", size: 100_000)
        fs.file(base + "iPhone16,2 27.0 (24A437)/s.bin", size: 100_000)
        fs.file("Library/Developer/Xcode/watchOS DeviceSupport/Watch6,1 9.1 (20S1)/s.bin", size: 100_000)
        let r = try await scan("ios-device-support")
        XCTAssertEqual(Set(r.items.map(\.name)), ["iPhone14,2 26.6.2 (23G90)", "iPhone15,2 26.4 (23E246)", "iPhone16,1 26.6 (23G71)"])
        XCTAssertGreaterThanOrEqual(r.protectedBytes, 200_000, "newest iOS and the lone watchOS are protected")
        XCTAssertEqual(r.rule.tier, .yellow)
    }

    func testDeviceSupportVersionOrdering() {
        XCTAssertEqual(CleanScanner.osVersion(fromDeviceSupportName: "iPhone14,2 26.6.2 (23G90)"), [26, 6, 2])
        XCTAssertEqual(CleanScanner.osVersion(fromDeviceSupportName: "15.4 (19E241)"), [15, 4])
        XCTAssertTrue(CleanScanner.versionLess([26, 6], [26, 6, 2]))
        XCTAssertTrue(CleanScanner.versionLess([9, 9], [26, 0]))
        XCTAssertFalse(CleanScanner.versionLess([26, 0], [26]))
    }

    func testHuggingFacePerModel() async throws {
        let hub = ".cache/huggingface/hub/"
        fs.file(hub + "models--Systran--faster-whisper-large-v3/blobs/a", size: 300_000)
        fs.file(hub + "models--facebook--nllb/blobs/a", size: 200_000)
        fs.file(hub + "datasets--org--data/blobs/a", size: 100_000)
        fs.file(hub + ".locks/models--x/lock", size: 10)
        fs.file(".cache/huggingface/xet/chunk", size: 50_000)
        let r = try await scan("huggingface")
        XCTAssertEqual(Set(r.items.map(\.name)), ["Systran/faster-whisper-large-v3", "facebook/nllb", "org/data", "xet"])
        XCTAssertEqual(r.items.first?.name, "Systran/faster-whisper-large-v3", "biggest first")
        XCTAssertEqual(r.rule.deletion, .trash)
    }

    func testNodeModulesOnlyOldProjects() async throws {
        fs.file("Developer/old-app/package.json", ageDays: 90)
        fs.file("Developer/old-app/src/index.js", ageDays: 90)
        fs.file("Developer/old-app/node_modules/dep/index.js", size: 80_000, ageDays: 5)   // install is recent, project idle
        fs.file("Developer/fresh-app/package.json", ageDays: 2)
        fs.file("Developer/fresh-app/node_modules/dep/index.js", size: 80_000, ageDays: 2)
        fs.file("Developer/no-package/node_modules/dep/index.js", size: 80_000, ageDays: 90)
        fs.file("Developer/mono/pkgs/a/package.json", ageDays: 60)
        fs.file("Developer/mono/pkgs/a/node_modules/x/i.js", size: 80_000, ageDays: 60)
        let r = try await scan("node-modules")
        XCTAssertEqual(Set(r.items.compactMap { $0.url?.deletingLastPathComponent().lastPathComponent }), ["old-app", "a"])
        XCTAssertTrue(r.items.allSatisfy { $0.name == "node_modules" })
        // fingerprint is the node_modules content (5 days), lastUsed is project activity (~90 days)
        let old = try XCTUnwrap(r.items.first { $0.path?.contains("old-app") == true })
        XCTAssertLessThan(try XCTUnwrap(old.lastUsed), Date().addingTimeInterval(-80 * 86_400))
    }

    func testFinalCutRenderFilesOnly() async throws {
        fs.file("Movies/Wedding.fcpbundle/Event 1/Render Files/r.mov", size: 90_000)
        fs.file("Movies/Wedding.fcpbundle/Event 1/Original Media/o.mov", size: 90_000)
        fs.file("Movies/Wedding.fcpbundle/Event 1/Proj/Render Files/r2.mov", size: 90_000)
        fs.file("Movies/Holiday.mov", size: 90_000)
        let r = try await scan("fcp-render-files")
        XCTAssertEqual(r.items.count, 2)
        XCTAssertTrue(r.items.allSatisfy { $0.path!.hasSuffix("Render Files") })
    }

    func testKeepNewestGeneric() async throws {
        let rule = Rule(id: "k", title: L10n(ru: "к", en: "k"), whySafe: L10n(ru: "к", en: "k"), tier: .yellow, category: .dev,
                        roots: ["~/Library/Caches/KN"], keepNewest: 1)
        fs.file("Library/Caches/KN/v1/a", ageDays: 30); fs.file("Library/Caches/KN/v2/a", ageDays: 5); fs.file("Library/Caches/KN/v3/a", ageDays: 20)
        let r = await CleanScanner(environment: fs.env()).scan(rule: rule)
        XCTAssertEqual(Set(r.items.map(\.name)), ["v1", "v3"])
        XCTAssertGreaterThan(r.protectedBytes, 0)
    }

    func testOverlapsAreDroppedAndSpecificRuleWins() async throws {
        fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 100_000, ageDays: 10)
        fs.file("Library/Caches/Adobe/Fonts/f.bin", size: 100_000, ageDays: 10)
        let ae = try rule("ae-disk-cache")
        // A greedy generic rule covering all of ~/Library/Caches/Adobe must lose the AE paths (and nothing may be double counted).
        var greedy = Rule(id: "greedy", title: L10n(ru: "г", en: "g"), whySafe: L10n(ru: "г", en: "g"), tier: .green, category: .system,
                          roots: ["~/Library/Caches"], priority: 900)
        greedy.excludeNames = []
        let res = await CleanScanner(environment: fs.env()).scan(rules: [ae, greedy])
        XCTAssertEqual(res.result(id: "ae-disk-cache")?.items.count, 1)
        XCTAssertEqual(res.result(id: "greedy")?.items.count, 0, "the Adobe folder contains an AE item owned by a better rule")
        XCTAssertEqual(res.totalBytes, res.result(id: "ae-disk-cache")!.bytes)
    }

    func testRuleWithForbiddenRootIsRejected() async throws {
        fs.file("Documents/thesis.docx")
        let bad = Rule(id: "bad", title: L10n(ru: "п", en: "b"), whySafe: L10n(ru: "п", en: "b"), tier: .green, category: .system, roots: ["~/Documents"])
        let r = await CleanScanner(environment: fs.env()).scan(rule: bad)
        XCTAssertEqual(r.status, .rejected); XCTAssertTrue(r.items.isEmpty)
    }

    func testTotalsAndGrouping() async throws {
        fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 1_000_000)
        fs.file(".cache/huggingface/hub/models--a--b/blobs/x", size: 2_000_000)
        fs.file("Downloads/big.dmg", size: 3_000_000, ageDays: 40)
        let rules = try loadCatalog()
        let res = await CleanScanner(environment: fs.env()).scan(rules: rules)
        XCTAssertGreaterThanOrEqual(res.bytes(tier: .green), 1_000_000)
        XCTAssertGreaterThanOrEqual(res.bytes(tier: .yellow), 2_000_000)
        XCTAssertGreaterThanOrEqual(res.bytes(tier: .red), 3_000_000)
        XCTAssertEqual(res.totalBytes, Tier.allCases.map { res.bytes(tier: $0) }.reduce(0, +))
        let groups = res.grouped()
        XCTAssertEqual(groups.map(\.tier), [.green, .yellow, .red])
        XCTAssertEqual(groups[0].categories.first?.category, .creative)
        XCTAssertTrue(res.result(id: "downloads")!.items[0].isInstaller)
    }

    func testCancellationStopsScan() async throws {
        for i in 0..<200 { fs.file("Library/Caches/Adobe/After Effects/26.0/f\(i).bin", size: 100) }
        let rules = try loadCatalog()
        let env = fs.env()
        let task = Task { await CleanScanner(environment: env).scan(rules: rules) }
        task.cancel()
        let res = await task.value
        XCTAssertTrue(res.cancelled)
    }

    func testProgressEventsAndModel() async throws {
        fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 500_000)
        let rules = Array(try loadCatalog().prefix(8))
        var started = 0, finished = 0, lastBytes: Int64 = 0, done = false
        for await ev in CleanScanner(environment: fs.env()).events(rules: rules) {
            switch ev {
            case .started(let n): XCTAssertEqual(n, 8)
            case .ruleStarted: started += 1
            case .ruleFinished: finished += 1
            case .bytesFound(let b): lastBytes = max(lastBytes, b)
            case .finished: done = true
            }
        }
        XCTAssertEqual(started, 8); XCTAssertEqual(finished, 8); XCTAssertTrue(done)
        _ = lastBytes
    }

    @MainActor
    func testScanModelReachesDone() async throws {
        fs.file("Library/Caches/Adobe/After Effects/26.0/a.bin", size: 500_000)
        let model = ScanModel()
        model.start(rules: [try rule("ae-disk-cache")], environment: fs.env())
        for _ in 0..<200 where model.phase == .scanning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(model.completedRules, 1)
        XCTAssertGreaterThanOrEqual(model.result?.totalBytes ?? 0, 500_000)
    }
}
