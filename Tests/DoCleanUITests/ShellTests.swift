import XCTest
import AppKit
import DoCleanCore
@testable import DoCleanUI

private struct NoCommands: CommandRunner {
    func locate(_ name: String) -> String? { nil }
    func run(_ executable: String, _ args: [String]) -> CommandOutput { CommandOutput(status: 1, stdout: "") }
}

@MainActor
final class ShellTests: XCTestCase {
    private var home: URL!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("doclean-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func rule(_ id: String, _ tier: Tier) -> Rule {
        Rule(id: id, title: L10n(ru: id, en: id), whySafe: L10n(ru: "т", en: "t"), tier: tier, category: .system)
    }

    private func makeModel(rules: [Rule] = []) -> AppModel {
        let env = DoCleanEnvironment(home: home, tmpDir: home.appendingPathComponent("tmp"),
                                     probe: FixedAppStateProbe(), runner: NoCommands())
        return AppModel(environment: env, rules: rules, disk: DiskSpace(free: 1, total: 2),
                        settingsStore: SettingsStore(fileURL: home.appendingPathComponent("settings.json")),
                        showOnboarding: true)
    }

    func testExcludedRulesAreNotScanned() {
        let m = makeModel(rules: [rule("a", .green), rule("b", .green)])
        m.mode = .quick
        m.settings.setRule("b", excluded: true)
        XCTAssertEqual(m.rulesForMode.map(\.id), ["a"])
    }

    func testExcludedPathsReachTheEnvironment() {
        let m = makeModel()
        m.settings.exclude(path: "~/Projects")
        XCTAssertFalse(m.scanEnvironment.exclusions.isEmpty)
        XCTAssertFalse(m.tools.environment.exclusions.isEmpty, "tools walk with the same exclusions")
    }

    func testSettingsArePersisted() {
        let m = makeModel()
        m.settings.settings.reminderDays = 14
        m.settings.settings.greenMethod = .trash
        let again = SettingsStore(fileURL: home.appendingPathComponent("settings.json")).load()
        XCTAssertEqual(again.reminderDays, 14)
        XCTAssertEqual(again.greenMethod, .trash)
    }

    func testLargeThresholdComesFromSettings() {
        let store = SettingsStore(fileURL: home.appendingPathComponent("settings.json"))
        var s = AppSettings()
        s.largeFileThreshold = 250_000_000
        try? store.save(s)
        let env = DoCleanEnvironment(home: home, tmpDir: home, probe: FixedAppStateProbe(), runner: NoCommands())
        let m = AppModel(environment: env, rules: [], disk: DiskSpace(free: 1, total: 2), settingsStore: store, showOnboarding: false)
        XCTAssertEqual(m.tools.largeMinMB, 250)
    }

    func testQuickCleanScansGreenOnly() {
        let m = makeModel(rules: [rule("g", .green), rule("y", .yellow)])
        m.mode = .all
        m.quickClean()
        XCTAssertEqual(m.mode, .quick)
        XCTAssertEqual(m.section, .home)
        XCTAssertEqual(m.stage, .scanning)
        XCTAssertFalse(m.showOnboarding)
        XCTAssertEqual(m.rulesForMode.map(\.id), ["g"])
        m.cancelScan()
    }

    func testOnboardingFinishIsRemembered() {
        let m = makeModel()
        XCTAssertTrue(m.showOnboarding)
        let key = AppModel.onboardedKey
        let old = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(old, forKey: key) }
        m.finishOnboarding()
        XCTAssertFalse(m.showOnboarding)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
    }

    func testHistoryStatsFromOverride() {
        let m = makeModel(rules: [rule("g", .green)])
        XCTAssertEqual(m.historyStats().cleanupCount, 0)
        m.historyEntriesOverride = ScreenSnapshots.demoHistory()
        XCTAssertEqual(m.historyStats().cleanupCount, 12)
        XCTAssertGreaterThan(m.historyStats().totalFreed, 100_000_000_000)
    }

    func testFixedAccessProbe() {
        XCTAssertEqual(FixedAccess(.granted).check(), .granted)
        XCTAssertEqual((FullDiskAccessProbe(candidates: []) as any AccessChecking).check(), .unknown)
    }

    func testIconMasterIs1024() throws {
        let data = try AppIconRenderer.png(scale: 1)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 1024)
        XCTAssertEqual(rep.pixelsHigh, 1024)
    }
}
