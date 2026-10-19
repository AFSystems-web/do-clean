import XCTest
@testable import DoCleanCore

final class CatalogTests: XCTestCase {
    func testCatalogLoadsAndIsWellFormed() throws {
        let rules = try loadCatalog()
        XCTAssertGreaterThan(rules.count, 30)
        XCTAssertEqual(Set(rules.map(\.id)).count, rules.count, "ids unique")
        let palettes: Set = ["adobe", "xcode", "ai", "downloads", "system"]
        for r in rules {
            XCTAssertFalse(r.title.ru.isEmpty); XCTAssertFalse(r.title.en.isEmpty, r.id)
            XCTAssertFalse(r.whySafe.ru.isEmpty); XCTAssertFalse(r.whySafe.en.isEmpty, r.id)
            XCTAssertTrue(palettes.contains(r.palette), "\(r.id) palette \(r.palette)")
            if r.deletion == .command {
                XCTAssertNoThrow(try SafetyGuard(home: URL(fileURLWithPath: "/x")).checkCommand(r.command), r.id)
            } else if r.kind != .dockerPrune {
                XCTAssertFalse(r.roots.isEmpty, r.id)
            }
            if r.tier == .green { XCTAssertTrue(r.defaultSelected) } else { XCTAssertFalse(r.defaultSelected) }
            if r.tier == .red { XCTAssertEqual(r.deletion, .trash, "red goes to Trash: \(r.id)") }
        }
    }

    func testRequiredRulesPresent() throws {
        let ids = Set(try loadCatalog().map(\.id))
        for id in ["ae-disk-cache", "ios-device-support", "huggingface", "node-modules", "downloads", "trash",
                   "simulators-unavailable", "homebrew-cleanup", "docker", "xcode-derived-data", "user-caches"] {
            XCTAssertTrue(ids.contains(id), id)
        }
    }

    /// `Bundle.module` is not found inside "do clean.app/Contents/Resources"; our lookup must be.
    func testRulesFolderFoundInsideAppBundleLayout() throws {
        let fs = FakeFS()
        let source = try XCTUnwrap(RuleCatalog.locateRulesFolder())
        // …/DoClean_DoCleanCore.bundle/(Contents/Resources/)Rules  -> bundle root
        var bundle = source
        while bundle.pathExtension != "bundle" { bundle = bundle.deletingLastPathComponent() }
        let resources = fs.root.appendingPathComponent("do clean.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundle, to: resources.appendingPathComponent(bundle.lastPathComponent))
        let found = try XCTUnwrap(RuleCatalog.locateRulesFolder(searchRoots: [resources]))
        XCTAssertTrue(found.path.hasPrefix(resources.path))
        XCTAssertEqual(try RuleCatalog.load(from: found).count, try loadCatalog().count)
        XCTAssertNil(RuleCatalog.locateRulesFolder(searchRoots: [fs.root.appendingPathComponent("nowhere")]))
    }

    func testDuplicateIDsRejected() throws {
        let fs = FakeFS()
        let json = #"[{"id":"a","tier":"green","category":"system","title":{"ru":"а","en":"a"},"whySafe":{"ru":"а","en":"a"}}]"#
        try json.write(to: fs.root.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        try json.write(to: fs.root.appendingPathComponent("2.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RuleCatalog.load(from: fs.root))
    }

    /// The contract from the plan: no catalog root may fall into a forbidden path.
    func testEveryCatalogRootPassesSafetyGuard() throws {
        let fs = FakeFS()
        let env = fs.env(allowRealTmp: true)
        for r in try loadCatalog() {
            for root in r.roots {
                XCTAssertNoThrow(try env.guardrail.checkRoot(env.expand(root)), "\(r.id): \(root)")
            }
        }
    }

    /// Same for the real machine's paths (pure string checks, nothing is read or modified).
    func testEveryCatalogRootPassesSafetyGuardOnRealHomePaths() throws {
        let env = DoCleanEnvironment.live()
        for r in try loadCatalog() {
            for root in r.roots {
                XCTAssertNoThrow(try env.guardrail.checkRoot(env.expand(root)), "\(r.id): \(root)")
            }
        }
    }
}

final class SafetyGuardTests: XCTestCase {
    var fs: FakeFS!
    var guardrail: SafetyGuard!
    override func setUp() { fs = FakeFS(); guardrail = fs.env().guardrail }

    func check(_ item: URL, roots: [URL], scanned: Date? = nil, current: Date? = nil, rootItself: Bool = false) throws {
        try guardrail.check(item: item, roots: roots, allowRootItself: rootItself, scannedFingerprint: scanned, currentFingerprint: current)
    }

    func testForbiddenRootsRejected() throws {
        for rel in ["Documents", "Desktop", "Pictures", "Library/Keychains", "Library/Mobile Documents/com~apple~CloudDocs",
                    "Library/Application Support/Google/Chrome/Default", "Library/Safari", ".ssh", "Pictures/Photos Library.photoslibrary"] {
            let u = fs.path(rel)
            XCTAssertThrowsError(try guardrail.checkPath(u), rel) { XCTAssertTrue("\($0)".contains("forbidden"), "\($0)") }
        }
        XCTAssertThrowsError(try guardrail.checkPath(fs.home))
    }

    func testRootCoveringForbiddenRejected() {
        XCTAssertThrowsError(try guardrail.checkPath(fs.path("Library"))) { XCTAssertEqual($0 as? SafetyViolation, .coversForbidden(SafetyGuard.canonical(self.fs.path("Library")))) }
    }

    func testOutsideAllowedBasesRejected() {
        for p in ["/System/Library", "/usr/bin", "/Library/Caches", "/Applications/Safari.app", "/private/etc"] {
            XCTAssertThrowsError(try guardrail.checkPath(URL(fileURLWithPath: p)), p)
        }
    }

    func testAdobeMediaCacheExceptionAllowed() {
        XCTAssertNoThrow(try guardrail.checkPath(fs.path("Library/Application Support/Adobe/Common/Media Cache Files")))
        XCTAssertThrowsError(try guardrail.checkPath(fs.path("Library/Application Support/Adobe/Common")))
        XCTAssertThrowsError(try guardrail.checkPath(fs.path("Library/Application Support/Adobe")))
    }

    func testItemMustBeInsideRoot() throws {
        let root = fs.path("Library/Caches"); let other = fs.file("Downloads/x.bin")
        fs.file("Library/Caches/app/a.bin")
        XCTAssertNoThrow(try check(fs.path("Library/Caches/app"), roots: [root]))
        XCTAssertThrowsError(try check(other, roots: [root])) { XCTAssertTrue("\($0)".contains("outside")) }
        // sibling with the same prefix must not count as inside
        fs.file("Library/Caches2/z.bin")
        XCTAssertThrowsError(try check(fs.path("Library/Caches2/z.bin"), roots: [root]))
    }

    func testRootItselfRefusedUnlessAllowed() throws {
        let root = fs.path("Library/Caches/x"); fs.file("Library/Caches/x/a")
        XCTAssertThrowsError(try check(root, roots: [root])) { XCTAssertEqual($0 as? SafetyViolation, .isRootItself(SafetyGuard.canonical(root))) }
        XCTAssertNoThrow(try check(root, roots: [root], rootItself: true))
    }

    func testSymlinkEscapeRejected() throws {
        let root = fs.path("Library/Caches/app"); fs.file("Library/Caches/app/keep.bin")
        let secret = fs.file("Documents/thesis.docx")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fs.path("Documents"))
        XCTAssertThrowsError(try check(link, roots: [root]))
        // item below a symlinked directory
        XCTAssertThrowsError(try check(link.appendingPathComponent("thesis.docx"), roots: [root]))
        // symlink to a file outside the root
        let flink = root.appendingPathComponent("flink")
        try FileManager.default.createSymbolicLink(at: flink, withDestinationURL: secret)
        XCTAssertThrowsError(try check(flink, roots: [root]))
        // a link that stays inside the root is fine
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createSymbolicLink(at: inner, withDestinationURL: root.appendingPathComponent("keep.bin"))
        XCTAssertNoThrow(try check(inner, roots: [root]))
    }

    func testModifiedAfterScanRejected() throws {
        let root = fs.path("Library/Caches"); fs.file("Library/Caches/app/a")
        let scanned = Date().addingTimeInterval(-1000)
        XCTAssertThrowsError(try check(fs.path("Library/Caches/app"), roots: [root], scanned: scanned, current: Date())) {
            XCTAssertEqual($0 as? SafetyViolation, .modifiedAfterScan(self.fs.path("Library/Caches/app").path))
        }
        XCTAssertNoThrow(try check(fs.path("Library/Caches/app"), roots: [root], scanned: scanned, current: scanned))
    }

    func testMissingItemRejected() {
        XCTAssertThrowsError(try check(fs.path("Library/Caches/ghost"), roots: [fs.path("Library/Caches")]))
    }

    func testOnlyAllowListedCommands() {
        XCTAssertNoThrow(try guardrail.checkCommand(["brew", "cleanup", "--prune=all"]))
        XCTAssertThrowsError(try guardrail.checkCommand(["rm", "-rf", "/"]))
        XCTAssertThrowsError(try guardrail.checkCommand(["brew", "cleanup", "--prune=all", "; rm -rf ~"]))
    }
}
