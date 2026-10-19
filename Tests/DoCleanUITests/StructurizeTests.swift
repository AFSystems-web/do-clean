import XCTest
import DoCleanCore
@testable import DoCleanUI

@MainActor
final class StructurizeTests: XCTestCase {
    private var demo: StructurizeDemo.Home!

    override func setUp() async throws {
        demo = try StructurizeDemo.make()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: demo.home)
    }

    private func makeApp(realMoves: Bool = false) -> AppModel {
        let app = AppModel(environment: demo.environment, rules: [], allowRealClean: realMoves,
                           disk: DiskSpace(free: 1, total: 2),
                           settingsStore: SettingsStore(fileURL: demo.home.appendingPathComponent("settings.json")),
                           showOnboarding: false)
        app.structurize.journalStoreOverride = JournalStore(directory: demo.home.appendingPathComponent("journals"))
        app.structurize.sources = [.desktop]
        return app
    }

    private func waitFor(_ cond: () -> Bool) async throws {
        for _ in 0..<300 where !cond() { try await Task.sleep(for: .milliseconds(20)) }
    }

    private var desktopItems: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: demo.home.appendingPathComponent("Desktop").path)) ?? [])
    }

    func testPresetsAndDefaults() {
        let app = makeApp()
        let s = app.structurize!
        XCTAssertEqual(s.presets.prefix(4).map(\.id), ["type", "date", "creative", "minimal"])
        XCTAssertEqual(s.draft.id, StructurePreset.byTypeID)
        XCTAssertEqual(Set(s.presets.prefix(4).map(\.palette)).count, 4, "each built-in preset has its own palette")
        XCTAssertFalse(s.presets[0].treePreview().isEmpty)
        XCTAssertEqual(AppSection.structurize.title, "Порядок")
    }

    func testMaskParsing() {
        let m = StructurizeModel.parseMask("mp4, .MOV *.braw  clip_??.wav")
        XCTAssertEqual(m.extensions, ["mp4", "mov"])
        XCTAssertEqual(m.globs, ["*.braw", "clip_??.wav"])
    }

    func testSaveDraftAsUserPreset() {
        let app = makeApp()
        let s = app.structurize!
        var rule = s.draft.rules[0]
        rule.target = "Мои видео"
        s.updateRule(rule)
        XCTAssertTrue(s.draftDirty)
        let saved = s.saveDraftAsPreset(named: "Мой порядок")
        XCTAssertFalse(saved.isBuiltIn)
        XCTAssertEqual(s.presets.last?.title.ru, "Мой порядок")
        XCTAssertEqual(s.selectedPresetID, saved.id)
        XCTAssertEqual(app.settings.settings.structurePresets.first?.rules.first?.target, "Мои видео")
        s.deleteUserPreset(saved.id)
        XCTAssertTrue(app.settings.settings.structurePresets.isEmpty)
    }

    func testDryRunApplyMovesNothing() async throws {
        let app = makeApp(realMoves: false)
        let s = app.structurize!
        let before = desktopItems
        s.makePlan()
        try await waitFor { s.plan != nil }
        let plan = try XCTUnwrap(s.plan)
        XCTAssertGreaterThan(plan.count, 5)
        s.apply()
        try await waitFor { s.stage == .done }
        XCTAssertEqual(s.report?.dryRun, true)
        XCTAssertEqual(s.report?.moved.count, plan.count, "dry run reports every move it would make")
        XCTAssertNil(s.lastJournal, "dry run writes no journal, so there is nothing to undo")
        XCTAssertEqual(desktopItems, before, "dry run must not move anything")
    }

    func testRealApplyAndUndoOnDemoHome() async throws {
        let app = makeApp(realMoves: true)
        let s = app.structurize!
        let before = desktopItems
        s.select(StructurePreset.builtIn(id: StructurePreset.creativeID)!)
        s.makePlan()
        try await waitFor { s.plan != nil }
        XCTAssertTrue(s.plan!.moves.contains { $0.isUnit }, "project folders move whole")
        s.apply()
        try await waitFor { s.stage == .done }
        XCTAssertEqual(s.report?.dryRun, false)
        XCTAssertNotEqual(desktopItems, before)
        let journal = try XCTUnwrap(s.lastJournal)
        s.undo(journal)
        try await waitFor { !s.undoing && s.undoReport != nil }
        XCTAssertEqual(desktopItems, before, "undo puts everything back")
        XCTAssertEqual(s.journals.first?.isUndone, true)
    }

    func testDisplayNames() {
        XCTAssertEqual(displayFolderName("/Users/x/Downloads"), "Загрузки")
        XCTAssertEqual(displayFolderName("/Users/x/Stuff"), "Stuff")
        XCTAssertEqual(pluralWord(3, "файл", "файла", "файлов"), "файла")
    }
}
