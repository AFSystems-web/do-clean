# DoCleanCore — public API for the screens

`import DoCleanCore`. Everything below is `Sendable`; nothing mutates the disk except `Cleaner.clean(…, dryRun: false)`.

## 1. Setup
```swift
let env = DoCleanEnvironment.live()           // real home, NSWorkspace probe, Process runner
let rules = try RuleCatalog.load()            // Rules/*.json, finds the bundle inside "do clean.app/Contents/Resources" too
```
Tests/previews build `DoCleanEnvironment(home:tmpDir:probe:runner:)` over a temp folder (`FixedAppStateProbe`, fake `CommandRunner`).

## 2. Rule (decoded from JSON)
`id`, `title` / `subtitle` / `whySafe` (`L10n`: `.ru`, `.en`, `rule.title[.ru]`), `tier` (`.green/.yellow/.red`),
`category` (`.system/.creative/.dev/.ai/.personal`), `palette` ("adobe", "xcode", "ai", "downloads", "system"),
`requiresAppClosed` (bundle ids, trailing `*` = prefix), `deletion` (`.delete/.trash/.command`), `defaultSelected` (green only).

## 3. Scanning
```swift
// A) one-shot
let result = await CleanScanner(environment: env).scan(rules: rules)
// B) live UI: @MainActor @Observable
let model = ScanModel()
model.start(rules: rules, environment: env)   // bind: phase, bytesFound, progress, completedRules, totalRules,
model.cancel()                                //       currentRuleIDs, resultsByRule[ruleID], result
// C) raw events
for await ev in CleanScanner(environment: env).events(rules: rules) { … }   // .started .ruleStarted .bytesFound .ruleFinished .finished
```
Cancelling the Task (or the stream/model) stops the walk; `ScanResult.cancelled` is then true.

`ScanResult`: `results: [RuleResult]`, `totalBytes`, `bytes(tier:)`, `cleanableBytes`, `blockedBytes`,
`grouped() -> [TierGroup]` (tier → `categories: [CategoryGroup]` → `results`), `result(id:)`, `requests(ruleIDs:)`.

`RuleResult`: `rule`, `items: [ScanItem]` (biggest first), `bytes`, `status`, `blockedBy` (running bundle ids),
`protectedBytes` (left alone on purpose, e.g. newest DeviceSupport), `message`.
`status`: `.ready`, `.empty`, `.blockedByRunningApp` (show "Close After Effects to free 46 GB"), `.unavailable` (docker/brew/simctl missing), `.rejected`.

`ScanItem`: `id`, `name`, `path`/`url`, `bytes` (real allocated size), `fingerprint`, `lastUsed`, `isCommand`, `isInstaller`, `fileExtension`.
Downloads filters ("older than 30/90 days", "installers") are done in the UI over `ScanItem.lastUsed` / `isInstaller`.

## 4. Cleaning
```swift
let cleaner = Cleaner(environment: env, history: History(fileURL: History.defaultURL()))
let reqs = result.requests(ruleIDs: selectedIDs)              // or build CleanRequest(rule:items:) from checked items
let plan = await cleaner.clean(reqs)                          // dryRun defaults to TRUE
let done = await cleaner.clean(reqs, dryRun: false) { entry in … }   // per-item progress callback
```
`CleanReport`: `entries: [CleanEntry]` (`outcome`: `.removed/.wouldRemove/.skipped(reason)/.failed(reason)`), `freedBytes`, `skipped`, `failed`.
Before each item: app-running check → SafetyGuard (allowed base, forbidden list, inside rule root, symlink escape, **changed since scan**) → delete / Trash / allow-listed command. One failure never stops the rest. Real runs append to `History`.

## 5. History
`History(fileURL:)`: `entries()`, `totalFreed`, `freedByDay()` (for the chart). File: `~/Library/Application Support/do clean/history.json`.

## 6. Helpers
`formatBytes(_:)`, `ScanExport(result).jsonData()` (what `doclean scan --json` prints), `SafetyGuard.checkPath/check`.

## 7. CLI
`doclean scan [--tier green|yellow|red|all] [--json]` · `doclean clean --dry-run [--rules a,b] [--tier …]` ·
`doclean clean --yes --rules a,b` (real; refuses without `--yes` and without explicit `--rules`) · `doclean rules`.

## 8. Tools (stage 7) — `Sources/DoCleanCore/Tools/`
All tools only read. Results become a `CleanRequest` (Trash only, Documents/Desktop/Pictures allowed, still no Photos libraries, Keychains, Application Support, iCloud Drive internals) and are removed by `Cleaner`:
`cleaner.clean([tool.cleanRequest(selectedFiles)], dryRun: false)`. A tool request whose rule is not `.trash` is refused by the Cleaner.

Common: `ToolFile` (`path`, `name`, `bytes`, `modified`, `lastOpened`, `dateAdded`, `lastTouched`, `lastUsedOrModified`), `ToolProgress` (`filesVisited`, `bytesFound`, `phase`, `currentPath`),
`ToolProgressHandler`, `FileDateProvider` (`SpotlightFileDates()` default, `NoFileDates()` for tests).
Everything is cancelable by cancelling the Task. UI binding: `ToolModel<Output>` (`@MainActor @Observable`: `phase`, `progress`, `output`; `run { progress in await tool.find(progress: progress) }`, `cancel()`).

| Tool | Create | Call | Result |
|---|---|---|---|
| Large files | `LargeFilesFinder(environment:minBytes: 500 MB, limit: 500)` | `find(progress:)` | `[ToolFile]` biggest first |
| Old files | `OldFilesFinder(environment:minBytes: 50 MB, olderThanDays: 365)` | `find(progress:)` | `[ToolFile]` oldest first (not opened/modified; date added ignored) |
| Duplicates | `DuplicateFinder(environment:minBytes: 1 MB)` | `find(progress:)` | `[DuplicateGroup]` (`files`, `keep`, `keepIndex`, `removable`, `reclaimableBytes`, `cleanRequest(removing:keeping:)` — never includes the kept file) |
| Downloads | `DownloadsTool(environment:)` | `list()`, `find(.olderThan(days:)/.installers/.all)` | `[DownloadItem]` (`file`, `isInstaller`, `isDirectory`, `reference` = latest of added/opened/modified) |
| node_modules | `NodeModulesFinder(environment:olderThanDays: 30)` (0 = all) | `find()` | `(projects: [NodeModulesProject], request: CleanRequest)` with `projectLastModified` |

Walk rules (large/old/dupes): home folder only; skips hidden items, symlinks, packages (`.photoslibrary`, `.app`, …), `node_modules`, `.git`, `~/Library`, `~/Applications`, `~/Music`, `~/Public`, iCloud placeholders (dataless files).
Duplicates: size → SHA-256 of first+last 64 KB → full SHA-256; hard links are not duplicates; suggested keep = a copy outside Downloads, then the oldest.
CLI (read-only): `doclean tools large|dupes|downloads|old [--json] [--min-mb N] [--days N] [--filter 30|90|installers|all]`.

## 9. Settings, access, stats, reminders (stage 8)
**Settings** — `AppSettings` (Codable, tolerant of missing/unknown values): `excludedPaths` (`~` ok), `excludedRuleIDs`, `reminderDays` (0 = off, default 7),
`largeFileThreshold` (bytes, default 500 MB), `greenMethod` (`.delete` | `.trash`), `language` (`.ru`/`.en`), `firstLaunchAt`, `lastReminderAt`.
`SettingsStore(fileURL: SettingsStore.defaultURL())` → `load()` / `save(_:)` (`~/Library/Application Support/do clean/settings.json`).
`@MainActor @Observable SettingsModel(store:)` — bind to `settings`, saved on every change; helpers `exclude(path:)`, `include(path:)`, `setRule(_:excluded:)`.

**Applying them** — one line each:
```swift
let env = DoCleanEnvironment.live().applying(settings)                 // exclusions enforced by CleanScanner, all tools and Cleaner
let cleaner = Cleaner(environment: .live(), settings: settings, history: history)   // also applies greenMethod
let large = LargeFilesFinder(environment: env, settings: settings)    // threshold from settings
```
Excluded rules disappear from `ScanResult` (not scanned); items inside / containing an excluded path are dropped; the Cleaner re-checks and skips with "excluded path" / "rule excluded".
`greenMethod == .trash` turns green `.delete` rules into Trash moves (command rules unaffected); `CleanEntry.method` reports what really happened.

**Full Disk Access** — `FullDiskAccessProbe().check() -> .granted/.denied/.unknown` (opens `~/Library/Safari/Bookmarks.plist` etc. read-only; `.unknown` = none of the paths exist). Poll it while onboarding. `FullDiskAccessProbe.settingsURL` opens the right Settings pane.

**Stats** — `HistoryStats(history:rules:)`: `totalFreed`, `cleanupCount`, `lastCleanup`, `biggest`, `byCategory() -> [RuleCategory: Int64]`, `byRule()`, `perDay(last:)`, `perWeek(last:)` (zero-filled `[Bucket(start, bytes)]`), `freed(since:)`.

**Reminders** — `ReminderScheduler().nextReminder(settings:lastCleanup:now:) -> Date?` (nil = off; schedule a notification at this date), `isDue(...)` (show it now, then set `settings.lastReminderAt = now`), `dueDate(...)`. Fires at 10:00 local, `reminderDays` after the last cleanup (or first launch), never more often than once per `reminderDays`.
`lastCleanup` = `HistoryStats.lastCleanup`.

## 10. Structurize (stage 11) — `Sources/DoCleanCore/Structurize/`
Sorts files into folders. **Only moves**: never deletes (except removing empty folders it created itself, on undo), never overwrites. Everything is journaled and undoable.

```swift
let presets = settings.allStructurePresets()                 // built-ins (language-aware) + user presets saved in AppSettings.structurePresets
let plan = try await StructurePlanner(environment: env).plan(sources: [downloads, desktop], preset: preset,
                                                             options: PlanOptions(recursive: false, language: .ru))   // read-only
let exec = StructureExecutor(environment: env)               // journals in ~/Library/Application Support/do clean/structurize/
let dry  = await exec.apply(plan)                            // dryRun defaults to TRUE
let done = await exec.apply(plan, dryRun: false) { move in … }   // ApplyReport: moved, skipped, failed, createdFolders, journalID
let undo = await exec.undo(exec.journals.latestUndoable()!, dryRun: false)   // UndoReport: restored, failed, removedFolders, keptFolders, recreatedFolders
```
- **Presets**: `StructurePreset.builtIn(language:)` → `type` «По типу», `date` «По дате», `creative` «Творческий», `minimal` «Минимал». A preset = `rules: [StructureRule]` (name, enabled, extensions, globs, utTypes, target folder with `{year}/{month}/{monthName}`, optional olderThanDays/newerThanDays), `folders` (created empty), `strategy` (`.rules` | `.creative` + `projectLayout` folder names). Everything is Codable and editable; `preset.duplicated()` makes a user copy to store in `AppSettings.structurePresets`.
- **MovePlan**: `moves: [PlannedMove]` (source → destination, bytes, `isUnit`), `skipped: [SkippedEntry]` (reason: hidden, symlink, bundle, busy, iCloudPlaceholder, partialDownload, excluded, forbidden, projectUnit, projectFile, alreadyInPlace, noRule, targetBlocked), `newFolders`, `count`, `bytes`, `summary()` (per top folder), `afterTree: [PlanTreeNode]` (per source: folders with counters, files/projects as leaves).
- **Protections**: a folder with .prproj/.aep/.blend/.xcodeproj/.fcpbundle/.git/Package.swift/… (≤3 levels deep) is a *project unit*: never entered; only the Creative preset moves it, whole, into `Проекты/`. Loose project files are never moved. Skipped: `.app` & bundles, hidden, symlinks, iCloud placeholders, partial downloads, files open now (`lsof`) or changed in the last minute, SafetyGuard-forbidden paths, user exclusions. Nothing leaves the chosen source folder (targets are sanitised, no `..`). Name conflicts → `name 2.ext`. `recursive: true` also looks into ordinary sub-folders.
- **Executor**: re-validates every move right before doing it (still inside the root, unchanged since the plan, destination free — otherwise the next free ` N` name), writes the journal (JSONL, one line before each move, so a crash is still undoable), `undo` restores in reverse, recreates missing parent folders, removes only folders the run created and only if empty, never overwrites an occupied original place and reports it.
- **CLI**: `doclean structurize plan --preset type|date|creative|minimal --source DIR… [--recursive] [--lang en] [--json]` (read-only) · `apply … --yes` · `undo --yes [--journal ID]` · `list` · `--home DIR` to try it on a fake home.
