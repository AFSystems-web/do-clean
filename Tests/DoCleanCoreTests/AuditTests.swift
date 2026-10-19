import XCTest
@testable import DoCleanCore

/// Stage 9 audit: nothing may remove or move a whole home, a root, or Documents/Desktop/Pictures.
final class AuditTests: XCTestCase {
    var fs: FakeFS!
    override func setUp() { fs = FakeFS() }

    func toolRequest(_ paths: [URL]) -> CleanRequest {
        ToolCleanup.request(id: "t", title: L10n(ru: "t", en: "t"), files: paths.map {
            ToolFile(path: $0.path, name: $0.lastPathComponent, bytes: 1, modified: Date.distantPast.addingTimeInterval(1e9))
        })
    }

    func testToolRequestsNeverRemoveWholeFolders() async throws {
        let docs = fs.file("Documents/a.txt").deletingLastPathComponent()
        let desktop = fs.file("Desktop/a.txt").deletingLastPathComponent()
        let pictures = fs.file("Pictures/a.png").deletingLastPathComponent()
        let movies = fs.file("Movies/a.mov").deletingLastPathComponent()
        let sub = fs.file("Documents/Projects/x.txt").deletingLastPathComponent()
        let downloads = fs.file("Downloads/a.txt").deletingLastPathComponent()
        let victims = [fs.home, docs, desktop, pictures, movies, sub, downloads, URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Users"), URL(fileURLWithPath: "/System")]
        let report = await fs.cleaner(fs.env()).clean([toolRequest(victims)], dryRun: false)
        XCTAssertEqual(report.entries.filter { $0.outcome == .removed }.count, 0, "\(report.entries.map(\.outcome))")
        for v in victims.prefix(7) { XCTAssertTrue(fs.exists(v), v.path) }
        XCTAssertTrue(fs.exists(fs.path("Documents/Projects/x.txt")))
    }

    func testCatalogRequestsNeverRemoveTopLevelHomeFolders() async throws {
        let movies = fs.file("Movies/a.mov").deletingLastPathComponent()
        let dev = fs.file("Developer/a.txt").deletingLastPathComponent()
        for rule in try loadCatalog().filter({ $0.deletion != .command }) {
            let items = [movies, dev, fs.home, fs.path("Documents"), fs.path("Library")].map { ScanItem(id: $0.path, name: $0.lastPathComponent, path: $0.path, bytes: 1, fingerprint: .distantPast) }
            let report = await fs.cleaner(fs.env()).clean([CleanRequest(rule: rule, items: items)], dryRun: false)
            XCTAssertEqual(report.entries.filter { $0.outcome == .removed }.count, 0, rule.id)
        }
        XCTAssertTrue(fs.exists(movies)); XCTAssertTrue(fs.exists(dev))
    }

    func testTopLevelFilesInHomeCanStillBeLargeFiles() throws {
        let f = fs.file("big.iso")
        XCTAssertNoThrow(try fs.env().guardrail.relaxedForTools().checkPath(f))
    }

    func testStructurizeNeverMovesTheChosenFolderOrHome() async throws {
        fs.file("Downloads/a.pdf")
        let env = fs.env()
        let p = try await StructurePlanner(environment: env).plan(sources: [fs.path("Downloads")], preset: StructurePreset.builtIn(id: "type")!)
        var forged = p
        let root = p.sources[0]
        forged.moves = [PlannedMove(source: root, destination: fs.path("Elsewhere").path, root: root, name: "Downloads", isDirectory: true, isUnit: true, bytes: 1, modified: nil, ruleName: "x")]
        forged.newFolders = []
        let r = await StructureExecutor(environment: env, journals: JournalStore(directory: fs.root.appendingPathComponent("j"))).apply(forged, dryRun: false)
        XCTAssertTrue(r.moved.isEmpty); XCTAssertTrue(fs.exists(fs.path("Downloads/a.pdf")))
        for bad in [fs.home, URL(fileURLWithPath: "/"), fs.path("Library")] {
            do { _ = try await StructurePlanner(environment: env).plan(sources: [bad], preset: StructurePreset.builtIn(id: "type")!); XCTFail(bad.path) } catch is StructurizeError {}
        }
    }

    /// Source-level guard: only the Cleaner and the Structurize executor may remove or move files.
    func testOnlyCleanerAndExecutorTouchFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/DoCleanCore")
        let allowed: Set<String> = ["Cleaner.swift", "StructureExecutor.swift", "SelfTest.swift", "History.swift", "Settings.swift", "StructureJournal.swift"]
        let patterns = ["removeItem(", "trashItem(", "moveItem(", "unlink(", "rmdir(", "replaceItem"]
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        while let u = en?.nextObject() as? URL {
            guard u.pathExtension == "swift", let text = try? String(contentsOf: u, encoding: .utf8), !allowed.contains(u.lastPathComponent) else { continue }
            if patterns.contains(where: text.contains) { offenders.append(u.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [])
    }
}
