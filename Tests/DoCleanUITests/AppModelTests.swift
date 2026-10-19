import XCTest
import DoCleanCore
@testable import DoCleanUI

private struct NoCommands: CommandRunner {
    func locate(_ name: String) -> String? { nil }
    func run(_ executable: String, _ args: [String]) -> CommandOutput { CommandOutput(status: 1, stdout: "") }
}

private func rule(_ id: String, _ tier: Tier, _ category: RuleCategory = .system, roots: [String] = []) -> Rule {
    Rule(id: id, title: L10n(ru: id, en: id), whySafe: L10n(ru: "т", en: "t"), tier: tier, category: category, roots: roots)
}

private func item(_ id: String, _ bytes: Int64) -> ScanItem {
    ScanItem(id: id, name: id, path: "/tmp/\(id)", bytes: bytes)
}

@MainActor
final class AppModelTests: XCTestCase {
    private func makeModel(rules: [Rule] = [], home: URL = FileManager.default.temporaryDirectory) -> AppModel {
        let env = DoCleanEnvironment(home: home, tmpDir: home.appendingPathComponent("tmp"),
                                     probe: FixedAppStateProbe(), runner: NoCommands())
        return AppModel(environment: env, rules: rules, disk: DiskSpace(free: 100_000_000_000, total: 500_000_000_000))
    }

    private var sample: ScanResult {
        ScanResult(results: [
            RuleResult(rule: rule("g", .green), items: [item("g1", 10), item("g2", 20)]),
            RuleResult(rule: rule("y", .yellow, .ai), items: [item("y1", 100)]),
            RuleResult(rule: rule("r", .red, .personal), items: [item("r1", 1000), item("r2", 2000)]),
            RuleResult(rule: rule("b", .green, .creative), items: [item("b1", 5)], status: .blockedByRunningApp,
                       blockedBy: ["com.adobe.AfterEffects"]),
        ])
    }

    func testDryRunIsTheDefault() {
        XCTAssertTrue(makeModel().isDryRun)
        XCTAssertFalse(AppModel(environment: makeModel().environment, rules: [], allowRealClean: false).allowRealClean)
    }

    func testModesSelectTiers() {
        let m = makeModel(rules: [rule("g", .green), rule("y", .yellow), rule("r", .red)])
        m.mode = .quick
        XCTAssertEqual(m.rulesForMode.map(\.id), ["g"])
        m.mode = .deep
        XCTAssertEqual(m.rulesForMode.map(\.id), ["g", "y"])
        m.mode = .all
        XCTAssertEqual(m.rulesForMode.map(\.id), ["g", "y", "r"])
    }

    func testDefaultSelectionGreenOnly() {
        let m = makeModel()
        m.finishScan(sample)
        XCTAssertEqual(m.selection["g"], ["g1", "g2"])
        XCTAssertNil(m.selection["y"])
        XCTAssertNil(m.selection["r"])
        XCTAssertNil(m.selection["b"], "blocked rules are never preselected")
        XCTAssertEqual(m.selectedBytes, 30)
        XCTAssertEqual(m.stage, .results)
    }

    func testRedIsItemByItemOnly() throws {
        let m = makeModel()
        m.finishScan(sample)
        let red = try XCTUnwrap(m.lastResult?.result(id: "r"))
        XCTAssertFalse(m.canToggleRule(red))
        m.toggleRule(red)
        XCTAssertEqual(m.selectedBytes(red), 0)
        m.toggleItem(red.items[0], in: red)
        XCTAssertEqual(m.check(red), .some)
        XCTAssertEqual(m.selectedBytes(red), 1000)
    }

    func testBlockedRuleCannotBeSelected() throws {
        let m = makeModel()
        m.finishScan(sample)
        let blocked = try XCTUnwrap(m.lastResult?.result(id: "b"))
        m.toggleRule(blocked)
        m.toggleItem(blocked.items[0], in: blocked)
        XCTAssertEqual(m.selectedBytes(blocked), 0)
        XCTAssertFalse(m.requests.contains { $0.rule.id == "b" })
    }

    func testRequestsFollowSelection() throws {
        let m = makeModel()
        m.finishScan(sample)
        let y = try XCTUnwrap(m.lastResult?.result(id: "y"))
        m.toggleRule(y)
        let g = try XCTUnwrap(m.lastResult?.result(id: "g"))
        m.toggleItem(g.items[0], in: g)
        let reqs = m.requests
        XCTAssertEqual(Set(reqs.map(\.rule.id)), ["g", "y"])
        XCTAssertEqual(reqs.first { $0.rule.id == "g" }?.items.map(\.id), ["g2"])
        XCTAssertEqual(m.selectedItemCount, 2)
        XCTAssertEqual(m.selectedBytes(tier: .yellow), 100)
    }

    /// The app's clean flow in dry-run (`-dry-run`) must not touch the disk.
    func testCleanFlowInDryRunLeavesFilesAlone() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("doclean-ui-\(UUID().uuidString)")
        let cache = home.appendingPathComponent("Library/Caches/TestApp")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent("blob.bin")
        try Data(count: 64 * 1024).write(to: file)
        defer { try? FileManager.default.removeItem(at: home) }

        let r = Rule(id: "test-cache", title: L10n(ru: "т", en: "t"), whySafe: L10n(ru: "т", en: "t"),
                     tier: .green, category: .system, roots: ["~/Library/Caches/TestApp"], itemMode: .children)
        let m = makeModel(rules: [r], home: home)
        let result = await CleanScanner(environment: m.environment).scan(rules: [r])
        XCTAssertGreaterThan(result.totalBytes, 0)
        m.finishScan(result)
        XCTAssertFalse(m.requests.isEmpty)

        m.clean()
        for _ in 0..<200 where m.stage != .finished { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(m.stage, .finished)
        let report = try XCTUnwrap(m.report)
        XCTAssertTrue(report.dryRun)
        XCTAssertGreaterThan(report.freedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "dry run must not delete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: History.defaultURL(home: home).path), "dry run writes no history")
        XCTAssertEqual(m.diskAfter?.free, (m.diskBefore?.free ?? 0) + report.freedBytes, "projected free space")
    }

    func testPlural() {
        XCTAssertEqual(plural(1, "объект", "объекта", "объектов"), "1 объект")
        XCTAssertEqual(plural(3, "объект", "объекта", "объектов"), "3 объекта")
        XCTAssertEqual(plural(11, "объект", "объекта", "объектов"), "11 объектов")
        XCTAssertEqual(plural(22, "объект", "объекта", "объектов"), "22 объекта")
        XCTAssertEqual(plural(1005, "объект", "объекта", "объектов"), "1005 объектов")
    }

    func testByteDisplay() {
        XCTAssertEqual(ByteDisplay(46_000_000_000).text, "46 ГБ")
        XCTAssertEqual(ByteDisplay(3_240_000_000).text, "3,2 ГБ")
        XCTAssertEqual(ByteDisplay(152_000_000).text, "152 МБ")
        XCTAssertEqual(ByteDisplay(1_500_000_000_000).text, "1,5 ТБ")
        XCTAssertTrue(DotMatrixFont.covers(DotMatrixNumber.format(ByteDisplay(987_654_321).value, decimals: 0) + "МБ"))
    }
}
