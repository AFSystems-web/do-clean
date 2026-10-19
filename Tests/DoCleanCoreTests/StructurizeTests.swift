import XCTest
@testable import DoCleanCore

final class StructurizeTests: XCTestCase {
    var fs: FakeFS!
    var src: URL { fs.path("Downloads") }
    override func setUp() { fs = FakeFS() }

    // MARK: helpers

    func snapshot(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let root = URL(fileURLWithPath: StructurePlanner.realPath(root.path))
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [])
        while let u = en?.nextObject() as? URL {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let rel = String(u.path.dropFirst(root.path.count))
            out[rel] = v?.isDirectory == true ? "d" : "f\(v?.fileSize ?? -1)"
        }
        return out
    }

    func plan(_ preset: String, recursive: Bool = false, lang: Language = .ru, env: DoCleanEnvironment? = nil, source: URL? = nil) async throws -> MovePlan {
        let e = env ?? fs.env()
        return try await StructurePlanner(environment: e).plan(sources: [source ?? src], preset: StructurePreset.builtIn(id: preset, language: lang)!,
                                                               options: PlanOptions(recursive: recursive, language: lang))
    }

    func executor(_ env: DoCleanEnvironment? = nil) -> StructureExecutor {
        let e = env ?? fs.env()
        return StructureExecutor(environment: e, journals: JournalStore(directory: fs.root.appendingPathComponent("journals")))
    }

    func targets(_ p: MovePlan) -> [String: String] {
        Dictionary(uniqueKeysWithValues: p.moves.map { ($0.name, $0.targetFolder) })
    }

    func setDate(_ url: URL, _ iso: String) {
        try! fs.fm.setAttributes([.modificationDate: ISO8601DateFormatter().date(from: iso)!], ofItemAtPath: url.path)
    }

    // MARK: presets

    func testBuiltInPresets() {
        let ru = StructurePreset.builtIn(language: .ru), en = StructurePreset.builtIn(language: .en)
        XCTAssertEqual(ru.map(\.id), ["type", "date", "creative", "minimal"])
        XCTAssertEqual(ru.map(\.title.ru), ["По типу", "По дате", "Творческий", "Минимал"])
        XCTAssertEqual(en[0].rules.first?.target, "Video")
        XCTAssertTrue(ru.allSatisfy(\.isBuiltIn))
        XCTAssertNotNil(StructurePreset.builtIn(cliName: "type")); XCTAssertNil(StructurePreset.builtIn(cliName: "nope"))
    }

    func testPresetCodableAndUserPresetsInSettings() throws {
        var p = StructurePreset.builtIn(id: "type")!.duplicated(as: "mine")
        p.rules[0].target = "Кино"; p.rules[1].enabled = false
        var s = AppSettings(); s.structurePresets = [p]
        let store = SettingsStore(fileURL: fs.root.appendingPathComponent("s.json"))
        try store.save(s)
        let back = store.load()
        XCTAssertEqual(back.structurePresets, [p]); XCTAssertFalse(back.structurePresets[0].isBuiltIn)
        XCTAssertEqual(back.allStructurePresets().count, 5)
    }

    func testByTypeRoutesEveryKind() async throws {
        let files = ["clip.MP4": "Видео", "shot.jpg": "Фото", "doc.pdf": "Документы", "a.zip": "Архивы", "app.dmg": "Установщики",
                     "song.mp3": "Аудио", "logo.psd": "Дизайн", "main.swift": "Код", "pic.heic": "Фото", "notes.txt": "Документы"]
        for f in files.keys { fs.file("Downloads/" + f, size: 5000) }
        fs.file("Downloads/mystery.xyz123", size: 5000)
        let p = try await plan("type")
        XCTAssertEqual(targets(p).filter { files[$0.key] != nil }, files)
        XCTAssertEqual(p.skipped.first { $0.name == "mystery.xyz123" }?.reason, .noRule)
        XCTAssertEqual(p.count, files.count)
        XCTAssertEqual(Set(p.newFolders.map { ($0 as NSString).lastPathComponent }), Set(files.values))
        let s = p.summary(); XCTAssertEqual(s.reduce(0) { $0 + $1.count }, files.count)
    }

    func testByTypeEnglishAndDisabledRule() async throws {
        fs.file("Downloads/clip.mp4"); fs.file("Downloads/doc.pdf")
        var preset = StructurePreset.builtIn(id: "type", language: .en)!
        preset.rules[0].enabled = false
        let p = try await StructurePlanner(environment: fs.env()).plan(sources: [src], preset: preset, options: PlanOptions(language: .en))
        XCTAssertEqual(targets(p), ["doc.pdf": "Documents"])
        XCTAssertEqual(p.skipped.first { $0.name == "clip.mp4" }?.reason, .noRule)
    }

    func testUTTypeRuleAndMask() async throws {
        fs.file("Downloads/Screenshot 2026.png"); fs.file("Downloads/x.webm"); fs.file("Downloads/b.png")
        let preset = StructurePreset(id: "u", title: L10n(ru: "u", en: "u"), rules: [
            StructureRule(name: "shots", globs: ["screenshot*"], target: "Скриншоты"),
            StructureRule(name: "movies", utTypes: ["public.movie"], target: "Фильмы"),
        ])
        let p = try await StructurePlanner(environment: fs.env()).plan(sources: [src], preset: preset)
        XCTAssertEqual(targets(p), ["Screenshot 2026.png": "Скриншоты", "x.webm": "Фильмы"])
    }

    func testByDate() async throws {
        let a = fs.file("Downloads/a.jpg"), b = fs.file("Downloads/b.pdf")
        setDate(a, "2026-03-15T12:00:00Z"); setDate(b, "2025-12-31T12:00:00Z")
        let ru = try await plan("date"), en = try await plan("date", lang: .en)
        XCTAssertEqual(targets(ru), ["a.jpg": "2026/03 Март", "b.pdf": "2025/12 Декабрь"])
        XCTAssertEqual(targets(en), ["a.jpg": "2026/03 March", "b.pdf": "2025/12 December"])
    }

    func testMinimal() async throws {
        fs.file("Downloads/new.txt", ageDays: 3); fs.file("Downloads/mid.txt", ageDays: 30); fs.file("Downloads/old.txt", ageDays: 200)
        let p = try await plan("minimal")
        XCTAssertEqual(targets(p), ["new.txt": "Входящие", "mid.txt": "В работе", "old.txt": "Архив"])
        // an empty-folder preset still creates its folders
        fs.file("Other/old2.txt", ageDays: 400)
        let q = try await plan("minimal", source: fs.path("Other"))
        XCTAssertEqual(Set(q.newFolders.map { ($0 as NSString).lastPathComponent }), ["Входящие", "В работе", "Архив"])
    }

    func testCreativeGroupsProjectsAndMovesUnitsWhole() async throws {
        for n in ["Botanica_intro.mp4", "Botanica_music.wav", "Botanica_final.mp4", "Botanica_render_1.mov", "Botanica_cut.fcpxml",
                  "IMG_0001.jpg", "IMG_0002.jpg", "lonely.txt", "Reels_a.mp4", "Reels_b.mp4"] { fs.file("Downloads/" + n, size: 5000) }
        fs.file("Downloads/Wedding/Wedding.prproj", size: 100); fs.file("Downloads/Wedding/Footage/a.mov", size: 7000)
        let p = try await plan("creative")
        let t = targets(p)
        XCTAssertEqual(t["Botanica_intro.mp4"], "Проекты/Botanica/Исходники")
        XCTAssertEqual(t["Botanica_music.wav"], "Проекты/Botanica/Звук")
        XCTAssertEqual(t["Botanica_final.mp4"], "Проекты/Botanica/Экспорт")
        XCTAssertEqual(t["Botanica_render_1.mov"], "Проекты/Botanica/Рендеры")
        XCTAssertEqual(t["Botanica_cut.fcpxml"], "Проекты/Botanica/Монтаж")
        XCTAssertEqual(t["Reels_a.mp4"], "Проекты/Reels/Исходники")
        XCTAssertNil(t["IMG_0001.jpg"], "camera prefixes are not projects"); XCTAssertNil(t["lonely.txt"])
        XCTAssertEqual(t["Wedding"], "Проекты")
        let unit = try XCTUnwrap(p.moves.first { $0.name == "Wedding" })
        XCTAssertTrue(unit.isUnit); XCTAssertTrue(unit.isDirectory); XCTAssertGreaterThanOrEqual(unit.bytes, 7000)
        XCTAssertFalse(p.moves.contains { $0.source.contains("Wedding/") }, "nothing inside the project is planned")
    }

    // MARK: project protection (critical)

    func testProjectFoldersAreNeverEntered() async throws {
        let markers = ["A/Project.prproj", "B/comp.aep", "C/scene.blend", "D/App.xcodeproj/project.pbxproj", "E/Lib.fcpbundle/info.plist",
                       "F/.git/HEAD", "G/Package.swift", "H/deep/er/Package.swift", "I/sub/render.blend"]
        for m in markers {
            let top = String(m.prefix(1))
            fs.file("Downloads/\(m)", size: 3000)
            fs.file("Downloads/\(top)/Footage/clip.mov", size: 3000); fs.file("Downloads/\(top)/Footage/shot.jpg", size: 3000)
            fs.file("Downloads/\(top)/notes.pdf", size: 3000)
        }
        fs.file("Downloads/plain/readme.pdf", size: 3000); fs.file("Downloads/loose.mp4", size: 3000)
        let before = snapshot(src)
        for preset in ["type", "date", "minimal", "creative"] {
            for recursive in [false, true] {
                let p = try await plan(preset, recursive: recursive)
                for m in p.moves {
                    let rel = String(m.source.dropFirst(src.path.count + 1))
                    let comps = rel.split(separator: "/")
                    if let first = comps.first, "ABCDEFGHI".contains(first) {
                        XCTAssertEqual(comps.count, 1, "\(preset)/\(recursive): moved something INSIDE project \(rel)")
                        XCTAssertEqual(preset, "creative", "only the creative preset relocates project folders (whole)")
                        XCTAssertTrue(m.isUnit)
                    }
                }
                if preset != "creative" { XCTAssertEqual(p.skipped.filter { $0.reason == .projectUnit }.count, 9, "\(preset)/\(recursive)") }
                else { XCTAssertEqual(p.moves.filter(\.isUnit).count, 9) }
                if recursive && preset != "creative" { XCTAssertTrue(p.moves.contains { $0.name == "readme.pdf" }, "plain folders are entered when recursive") }
            }
        }
        // and a real apply with every preset leaves each project tree byte-identical
        for preset in ["type", "creative"] {
            let f = FakeFS()
            for m in markers { let top = String(m.prefix(1)); f.file("Downloads/\(m)", size: 3000); f.file("Downloads/\(top)/Footage/clip.mov", size: 3000) }
            let proj = f.path("Downloads")
            let snapBefore = snapshot(proj)
            let env = f.env()
            let p = try await StructurePlanner(environment: env).plan(sources: [proj], preset: StructurePreset.builtIn(id: preset)!, options: PlanOptions(recursive: true))
            _ = await StructureExecutor(environment: env, journals: JournalStore(directory: f.root.appendingPathComponent("j"))).apply(p, dryRun: false)
            for (rel, kind) in snapBefore where rel.split(separator: "/").count > 1 {
                // every file that was inside a project still exists with the same relative path (under Проекты/ for creative)
                let prefix = preset == "creative" ? "/Проекты" : ""
                XCTAssertEqual(snapshot(proj)[prefix + rel], kind, "\(preset): \(rel)")
            }
        }
        _ = before
    }

    func testLooseProjectFilesAreNotMoved() async throws {
        for n in ["a.prproj", "b.aep", "c.blend", "Package.swift"] { fs.file("Downloads/" + n) }
        let p = try await plan("type")
        XCTAssertTrue(p.moves.isEmpty)
        XCTAssertEqual(p.skipped.filter { $0.reason == .projectFile }.count, 4)
    }

    // MARK: skips

    func testSkipsBundlesHiddenSymlinksPartialsAndPlaceholders() async throws {
        fs.file("Downloads/Some.app/Contents/Info.plist"); fs.file("Downloads/.secret.pdf"); fs.file("Downloads/movie.mp4.crdownload")
        fs.file("Downloads/Photos Library.photoslibrary/x.jpg"); fs.file("Downloads/.hidden.icloud"); fs.file("Downloads/ok.pdf")
        fs.file("Docs/target.pdf")
        try fs.fm.createSymbolicLink(at: fs.path("Downloads/link.pdf"), withDestinationURL: fs.path("Docs/target.pdf"))
        let p = try await plan("type")
        XCTAssertEqual(p.moves.map(\.name), ["ok.pdf"])
        let reasons = Dictionary(uniqueKeysWithValues: p.skipped.map { ($0.name, $0.reason) })
        XCTAssertEqual(reasons["Some.app"], .bundle); XCTAssertEqual(reasons[".secret.pdf"], .hidden); XCTAssertEqual(reasons["movie.mp4.crdownload"], .partialDownload)
        XCTAssertEqual(reasons["Photos Library.photoslibrary"], .forbidden); XCTAssertEqual(reasons["link.pdf"], .symlink)
    }

    func testBusyFilesViaLsofAndRecentModification() async throws {
        let open = fs.file("Downloads/open.pdf"); fs.file("Downloads/free.pdf"); fs.file("Downloads/fresh.pdf", ageDays: 0)
        fs.file("Downloads/Proj/x.blend"); let inProj = fs.file("Downloads/Proj/media/a.mov")
        var runner = FakeRunner(installed: ["lsof"])
        runner.outputs["-n -P -F n"] = CommandOutput(status: 0, stdout: "p123\nn\(open.path)\nn\(inProj.path)\nn/other/file\n")
        let p = try await plan("creative", env: fs.env(runner: runner))
        _ = p
        let q = try await plan("type", env: fs.env(runner: runner))
        XCTAssertEqual(q.moves.map(\.name), ["free.pdf"])
        let reasons = Dictionary(uniqueKeysWithValues: q.skipped.map { ($0.name, $0.reason) })
        XCTAssertEqual(reasons["open.pdf"], .busy); XCTAssertEqual(reasons["fresh.pdf"], .busy)
        // a project folder with an open file inside is busy as a whole
        XCTAssertEqual(p.skipped.first { $0.name == "Proj" }?.reason, .busy)
    }

    func testExcludedAndForbiddenSources() async throws {
        fs.file("Downloads/keep/a.pdf"); fs.file("Downloads/x.pdf"); fs.file("Downloads/skip.pdf")
        var s = AppSettings(); s.excludedPaths = ["~/Downloads/skip.pdf"]
        let p = try await plan("type", env: fs.env().applying(s))
        XCTAssertEqual(p.moves.map(\.name), ["x.pdf"]); XCTAssertEqual(p.skipped.first { $0.name == "skip.pdf" }?.reason, .excluded)
        for bad in [fs.home, fs.path("Library"), fs.path("Library/Application Support"), URL(fileURLWithPath: "/System"), fs.path(".ssh")] {
            do { _ = try await plan("type", source: bad); XCTFail("must refuse \(bad.path)") } catch let e as StructurizeError { _ = e } catch { XCTFail("\(error)") }
        }
        do { _ = try await plan("type", source: fs.path("nope")); XCTFail() } catch StructurizeError.sourceMissing { }
        // Documents / Desktop are valid sources for Structurize
        fs.file("Desktop/z.pdf"); fs.file("Documents/z.pdf")
        let d = try await plan("type", source: fs.path("Desktop")); XCTAssertEqual(d.count, 1)
        let c = try await plan("type", source: fs.path("Documents")); XCTAssertEqual(c.count, 1)
    }

    // MARK: conflicts and root confinement

    func testNameConflicts() async throws {
        fs.file("Downloads/a/photo.jpg", size: 1000); fs.file("Downloads/b/photo.jpg", size: 2000); fs.file("Downloads/photo.jpg", size: 3000)
        fs.file("Downloads/Фото/photo.jpg", size: 4000)                       // already on disk at the destination
        fs.file("Downloads/Фото/photo 2.jpg", size: 5000)
        let p = try await plan("type", recursive: true)
        let moved = p.moves.filter { $0.name == "photo.jpg" && $0.source != fs.path("Downloads/Фото/photo.jpg").path }
        XCTAssertEqual(moved.count, 3)
        let dests = Set(moved.map { ($0.destination as NSString).lastPathComponent })
        XCTAssertEqual(dests, ["photo 3.jpg", "photo 4.jpg", "photo 5.jpg"], "never reuses an existing name")
        XCTAssertEqual(Set(p.moves.map(\.destination)).count, p.moves.count)
        // and the second apply on the result is a no-op (already in place)
        _ = await executor().apply(p, dryRun: false)
        let again = try await plan("type", recursive: true)
        XCTAssertTrue(again.moves.isEmpty)
    }

    func testFolderConflictGetsSuffix() async throws {
        fs.file("Downloads/Проекты/Wedding/x.blend"); fs.file("Downloads/Wedding/y.blend")
        let p = try await plan("creative", recursive: true)
        let m = try XCTUnwrap(p.moves.first { $0.source.hasSuffix("/Downloads/Wedding") })
        XCTAssertEqual((m.destination as NSString).lastPathComponent, "Wedding 2")
    }

    func testTargetsCannotEscapeTheSourceRoot() async throws {
        fs.file("Downloads/a.pdf"); fs.file("Downloads/b.mp3")
        let preset = StructurePreset(id: "evil", title: L10n(ru: "e", en: "e"), rules: [
            StructureRule(name: "up", extensions: ["pdf"], target: "../../Documents/stolen"),
            StructureRule(name: "abs", extensions: ["mp3"], target: "/etc/../tmp"),
        ])
        let p = try await StructurePlanner(environment: fs.env()).plan(sources: [src], preset: preset)
        for m in p.moves { XCTAssertTrue(m.destination.hasPrefix(SafetyGuard.canonical(src) + "/"), m.destination) }
        XCTAssertEqual(targets(p), ["a.pdf": "Documents/stolen", "b.mp3": "etc/tmp"])
    }

    func testFileInTheWayOfTargetFolder() async throws {
        fs.file("Downloads/Фото", size: 10)               // a FILE called like the target folder
        fs.file("Downloads/x.jpg")
        let p = try await plan("type")
        XCTAssertEqual(p.skipped.first { $0.name == "x.jpg" }?.reason, .targetBlocked)
    }

    func testAfterTreeCounters() async throws {
        for n in ["a.mp4", "b.mp4", "c.jpg"] { fs.file("Downloads/" + n, size: 5000) }
        let t = try await plan("type").afterTree[0]
        XCTAssertEqual(t.count, 3)
        let video = try XCTUnwrap(t.children.first { $0.name == "Видео" })
        XCTAssertEqual(video.count, 2); XCTAssertEqual(video.children.map(\.name), ["a.mp4", "b.mp4"]); XCTAssertGreaterThan(video.bytes, 0)
    }

    // MARK: executor

    func testDryRunChangesNothing() async throws {
        for n in ["a.mp4", "b.pdf", "c.jpg"] { fs.file("Downloads/" + n) }
        let before = snapshot(fs.home)
        let p = try await plan("type")
        XCTAssertEqual(snapshot(fs.home), before, "planning is read-only")
        let report = await executor().apply(p)                      // dryRun defaults to true
        XCTAssertTrue(report.dryRun); XCTAssertEqual(report.moved.count, 3); XCTAssertNil(report.journalID)
        XCTAssertEqual(snapshot(fs.home), before)
        XCTAssertFalse(fs.exists(fs.root.appendingPathComponent("journals")), "no journal for a dry run")
    }

    func testApplyThenUndoRestoresIdenticalTree() async throws {
        for n in ["a.mp4", "b.pdf", "c.jpg", "d.mp3", "e.zip"] { fs.file("Downloads/" + n, size: 4000) }
        fs.file("Downloads/sub/f.mp4", size: 4000); fs.file("Downloads/Proj/x.blend"); fs.file("Downloads/Proj/m/a.mov")
        let before = snapshot(fs.home)
        let p = try await plan("type", recursive: true)
        let ex = executor()
        let report = await ex.apply(p, dryRun: false)
        XCTAssertEqual(report.moved.count, 6); XCTAssertTrue(report.failed.isEmpty)
        let after = snapshot(fs.home)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after.filter { $0.value != "d" }.count, before.filter { $0.value != "d" }.count, "no file was lost or duplicated")
        XCTAssertNotNil(after["/Downloads/Видео/a.mp4"]); XCTAssertNotNil(after["/Downloads/Видео/f.mp4"])
        XCTAssertEqual(after["/Downloads/Proj/m/a.mov"], before["/Downloads/Proj/m/a.mov"])

        let journal = try XCTUnwrap(ex.journals.latestUndoable())
        XCTAssertEqual(journal.id, report.journalID); XCTAssertEqual(journal.moves.count, 6); XCTAssertTrue(journal.finished)
        let dry = await ex.undo(journal)
        XCTAssertTrue(dry.dryRun); XCTAssertEqual(snapshot(fs.home), after)
        let u = await ex.undo(journal, dryRun: false)
        XCTAssertEqual(u.restored, 6); XCTAssertTrue(u.failed.isEmpty); XCTAssertTrue(u.keptFolders.isEmpty)
        XCTAssertEqual(snapshot(fs.home), before, "identical tree, created folders removed")
        XCTAssertNil(ex.journals.latestUndoable(), "an undone journal is finished")
        let twice = await ex.undo(try XCTUnwrap(ex.journals.load(id: journal.id)), dryRun: false)
        XCTAssertFalse(twice.failed.isEmpty)
    }

    func testApplyUndoWithDatePresetKeepsModificationDates() async throws {
        let a = fs.file("Downloads/a.pdf", ageDays: 400); setDate(a, "2025-01-10T10:00:00Z")
        let before = try fs.fm.attributesOfItem(atPath: a.path)[.modificationDate] as! Date
        let p = try await plan("date")
        let ex = executor(); _ = await ex.apply(p, dryRun: false)
        let moved = fs.path("Downloads/2025/01 Январь/a.pdf")
        XCTAssertTrue(fs.exists(moved)); XCTAssertEqual(try fs.fm.attributesOfItem(atPath: moved.path)[.modificationDate] as? Date, before)
        _ = await ex.undo(try XCTUnwrap(ex.journals.latestUndoable()), dryRun: false)
        XCTAssertTrue(fs.exists(a)); XCTAssertFalse(fs.exists(fs.path("Downloads/2025")))
    }

    func testExecutorNeverOverwrites() async throws {
        let a = fs.file("Downloads/a.pdf", size: 1000)
        let p = try await plan("type")
        // after planning, somebody puts a different file at the destination
        let blocker = fs.file("Downloads/Документы/a.pdf", size: 7777)
        let report = await executor().apply(p, dryRun: false)
        XCTAssertEqual(try Data(contentsOf: blocker).count, 7777)
        XCTAssertTrue(fs.exists(fs.path("Downloads/Документы/a 2.pdf")))
        XCTAssertFalse(fs.exists(a)); XCTAssertEqual(report.moved.count, 1)
    }

    func testChangedSinceThePlanIsSkipped() async throws {
        let a = fs.file("Downloads/a.pdf"); fs.file("Downloads/b.pdf")
        let p = try await plan("type")
        fs.touch(a)
        let r = await executor().apply(p, dryRun: false)
        XCTAssertEqual(r.moved.map(\.name), ["b.pdf"]); XCTAssertEqual(r.skipped.first?.move.name, "a.pdf"); XCTAssertTrue(fs.exists(a))
    }

    func testTamperedPlanCannotMoveOutsideOrFromForbidden() async throws {
        let doc = fs.file("Documents/thesis.pdf"); let a = fs.file("Downloads/a.pdf")
        var p = try await plan("type")
        let outside = fs.path("Documents/stolen.pdf").path
        let rootPath = p.sources[0]
        p.moves = [
            PlannedMove(source: a.path, destination: outside, root: rootPath, name: "a.pdf", isDirectory: false, isUnit: false, bytes: 1, modified: nil, ruleName: "x"),
            PlannedMove(source: doc.path, destination: rootPath + "/thesis.pdf", root: rootPath, name: "thesis.pdf", isDirectory: false, isUnit: false, bytes: 1, modified: nil, ruleName: "x"),
            PlannedMove(source: fs.path("Library/Keychains/x").path, destination: rootPath + "/x", root: rootPath, name: "x", isDirectory: false, isUnit: false, bytes: 1, modified: nil, ruleName: "x"),
        ]
        p.newFolders = []
        let r = await executor().apply(p, dryRun: false)
        XCTAssertTrue(r.moved.isEmpty); XCTAssertEqual(r.skipped.count, 3)
        XCTAssertTrue(fs.exists(a)); XCTAssertTrue(fs.exists(doc)); XCTAssertFalse(fs.exists(fs.path("Documents/stolen.pdf")))
    }

    func testUndoReportsWhatItCannotRestoreAndNeverOverwrites() async throws {
        for n in ["a.mp4", "b.pdf", "c.jpg"] { fs.file("Downloads/" + n, size: 2000) }
        let ex = executor()
        _ = await ex.apply(try await plan("type"), dryRun: false)
        try fs.fm.removeItem(at: fs.path("Downloads/Фото/c.jpg"))                      // user deleted one
        let squatter = fs.file("Downloads/a.mp4", size: 99)                               // original place taken
        let u = await ex.undo(try XCTUnwrap(ex.journals.latestUndoable()), dryRun: false)
        XCTAssertEqual(u.restored, 1)
        XCTAssertEqual(u.failed.count, 2)
        XCTAssertTrue(u.failed.contains { $0.reason.contains("no longer there") }); XCTAssertTrue(u.failed.contains { $0.reason.contains("occupied") })
        XCTAssertEqual(try Data(contentsOf: squatter).count, 99, "squatter untouched")
        XCTAssertTrue(fs.exists(fs.path("Downloads/Видео/a.mp4")), "the moved file stays where it is")
        XCTAssertNotNil(ex.journals.latestUndoable(), "not marked undone while something is left")
    }

    func testUndoRecreatesMissingParentsAndKeepsNonEmptyCreatedFolders() async throws {
        fs.file("Downloads/sub/deep/a.mp4", size: 2000)
        let ex = executor()
        _ = await ex.apply(try await plan("type", recursive: true), dryRun: false)
        XCTAssertFalse(fs.exists(fs.path("Downloads/sub/deep/a.mp4")))
        try fs.fm.removeItem(at: fs.path("Downloads/sub"))                                // parent folders gone
        fs.file("Downloads/Видео/mine.txt", size: 10)                                      // user added something to a created folder
        let u = await ex.undo(try XCTUnwrap(ex.journals.latestUndoable()), dryRun: false)
        XCTAssertEqual(u.restored, 1)
        XCTAssertTrue(u.recreatedFolders.contains { $0.hasSuffix("sub/deep") })
        XCTAssertTrue(fs.exists(fs.path("Downloads/sub/deep/a.mp4")))
        XCTAssertEqual(u.keptFolders.count, 1); XCTAssertTrue(fs.exists(fs.path("Downloads/Видео/mine.txt")))
    }

    func testJournalSurvivesATruncatedLastLine() async throws {
        fs.file("Downloads/a.pdf"); fs.file("Downloads/b.pdf")
        let ex = executor()
        let r = await ex.apply(try await plan("type"), dryRun: false)
        let url = fs.root.appendingPathComponent("journals/\(r.journalID!).jsonl")
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data(#"{"type":"move","move":{"from":"/x"#.utf8)); try h.close()
        let j = try XCTUnwrap(ex.journals.load(id: r.journalID!))
        XCTAssertEqual(j.moves.count, 2)
    }

    func testApplyOnAnEmptyPlanWritesNoJournal() async throws {
        fs.file("Downloads/zzz.xyz123")
        let ex = executor()
        let r = await ex.apply(try await plan("type"), dryRun: false)
        XCTAssertNil(r.journalID); XCTAssertTrue(ex.journals.list().isEmpty)
    }

    func testCancellationStopsPlanning() async throws {
        for i in 0..<50 { fs.file("Downloads/f\(i).pdf") }
        let env = fs.env()
        let source = src
        let t = Task { try await StructurePlanner(environment: env).plan(sources: [source], preset: StructurePreset.builtIn(id: "type")!) }
        t.cancel()
        let p = try await t.value
        XCTAssertLessThan(p.count, 50)
    }
}
