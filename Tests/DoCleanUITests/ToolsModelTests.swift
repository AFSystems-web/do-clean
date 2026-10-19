import XCTest
import DoCleanCore
@testable import DoCleanUI

private struct NoCommands: CommandRunner {
    func locate(_ name: String) -> String? { nil }
    func run(_ executable: String, _ args: [String]) -> CommandOutput { CommandOutput(status: 1, stdout: "") }
}

@MainActor
final class ToolsModelTests: XCTestCase {
    private var home: URL!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("doclean-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ rel: String, bytes: Int, seed: UInt8 = 7) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: seed, count: bytes).write(to: url)
        return url
    }

    private func makeApp() -> AppModel {
        let env = DoCleanEnvironment(home: home, tmpDir: home.appendingPathComponent("tmp"),
                                     probe: FixedAppStateProbe(), runner: NoCommands())
        let app = AppModel(environment: env, rules: [], disk: DiskSpace(free: 1, total: 2))
        app.tools.dates = NoFileDates()
        return app
    }

    private func wait(_ tools: ToolsModel, _ kind: ToolKind) async throws {
        for _ in 0..<300 where tools.isRunning(kind) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(tools.isRunning(kind))
    }

    func testDuplicatesKeepOneCopyAlways() async throws {
        _ = try write("Documents/a.bin", bytes: 2_000_000)
        _ = try write("Downloads/a copy.bin", bytes: 2_000_000)
        let app = makeApp()
        let tools = app.tools
        tools.run(.duplicates)
        try await wait(tools, .duplicates)
        let group = try XCTUnwrap(tools.duplicates.output?.first)
        XCTAssertEqual(group.files.count, 2)

        // Suggested keep is pre-selected (outside Downloads); the other copy is selected for the Trash.
        XCTAssertTrue(tools.keep[group.id]?.contains("/Documents/") ?? false)
        var reqs = tools.requests(for: .duplicates)
        XCTAssertEqual(reqs.flatMap(\.items).count, 1)
        XCTAssertTrue(reqs[0].items[0].path?.contains("/Downloads/") ?? false)

        // Switching the keep flips the selection; the kept file is never in the request.
        let other = try XCTUnwrap(group.files.first { $0.path.contains("/Downloads/") })
        tools.setKeep(other, in: group)
        reqs = tools.requests(for: .duplicates)
        XCTAssertEqual(reqs.flatMap(\.items).map(\.path), group.files.filter { $0.path != other.path }.map(\.path))
        tools.duplicateSelection.insert(other.path)
        XCTAssertFalse(tools.requests(for: .duplicates).flatMap(\.items).contains { $0.path == other.path })
        XCTAssertTrue(reqs.allSatisfy { $0.allowUserFolders && $0.rule.deletion == .trash })
    }

    func testLargeFilesNothingPreselected() async throws {
        _ = try write("Movies/big.mov", bytes: 3_000_000)
        let app = makeApp()
        let tools = app.tools
        tools.largeMinMB = 1
        tools.run(.large)
        try await wait(tools, .large)
        XCTAssertEqual(tools.large.output?.count, 1)
        XCTAssertTrue(tools.requests(for: .large).isEmpty, "personal files are never preselected")
        tools.largeSelection = Set(tools.large.output!.map(\.path))
        XCTAssertEqual(tools.selectedBytes(.large), tools.large.output!.first!.bytes)
    }

    func testToolCleanGoesThroughDryRunFlow() async throws {
        let file = try write("Movies/big.mov", bytes: 3_000_000)
        let app = makeApp()
        let tools = app.tools
        tools.largeMinMB = 1
        tools.run(.large)
        try await wait(tools, .large)
        tools.largeSelection = Set(tools.large.output!.map(\.path))

        app.confirmToolClean(tools.requests(for: .large), from: .large)
        XCTAssertTrue(app.confirming)
        XCTAssertEqual(app.requests.first?.rule.id, "tool-large-files")
        app.clean()
        for _ in 0..<200 where app.stage != .finished { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(app.report?.dryRun, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "dry run must not trash")

        app.backToDashboard()
        XCTAssertEqual(app.section, .tools)
        XCTAssertNil(app.cleanSourceTool)
        XCTAssertTrue(app.requests.isEmpty, "tool requests do not leak into the scan flow")
    }

    func testCancelledConfirmClearsToolRequests() {
        let app = makeApp()
        let req = CleanRequest(rule: Rule(id: "x", title: L10n(ru: "x", en: "x"), whySafe: L10n(ru: "x", en: "x"),
                                          tier: .red, category: .personal, deletion: .trash),
                               items: [ScanItem(id: "i", name: "i", path: "/tmp/i", bytes: 1)], allowUserFolders: true)
        app.confirmToolClean([req], from: .large)
        XCTAssertFalse(app.requests.isEmpty)
        app.confirming = false
        app.confirmDismissed()
        XCTAssertTrue(app.requests.isEmpty)
    }

    func testPhaseTitles() {
        XCTAssertEqual(phaseTitle(nil), "Обхожу домашнюю папку")
        XCTAssertEqual(phaseTitle("scan"), "Обхожу домашнюю папку")
        XCTAssertEqual(phaseTitle("quick-hash 3/40"), "Сравниваю содержимое · 3/40")
    }
}
