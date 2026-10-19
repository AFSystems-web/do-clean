import Foundation
import XCTest
@testable import DoCleanCore

/// A throw-away "Mac" in a temp folder: `home/`, `tmp/`, `trash/`. Nothing here touches the real home folder.
final class FakeFS: @unchecked Sendable {
    let root: URL
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    var trash: URL { root.appendingPathComponent("trash", isDirectory: true) }
    let fm = FileManager.default

    init() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("doclean-tests-\(UUID().uuidString)", isDirectory: true)
        root = base.resolvingSymlinksInPath()
        for d in [home, tmp, trash] { try! fm.createDirectory(at: d, withIntermediateDirectories: true) }
    }
    deinit { try? fm.removeItem(at: root) }

    func path(_ rel: String) -> URL { home.appendingPathComponent(rel) }

    /// Creates `rel` under home (or an absolute URL base) with `size` bytes, last modified `ageDays` ago.
    @discardableResult
    func file(_ rel: String, size: Int = 10_000, ageDays: Double = 10, base: URL? = nil) -> URL {
        let b = base ?? home
        let url = b.appendingPathComponent(rel)
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(count: size).write(to: url)
        let date = Date().addingTimeInterval(-ageDays * 86_400)
        try! fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        var dir = url.deletingLastPathComponent()
        while dir.path.count > b.path.count {
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: dir.path)
            dir = dir.deletingLastPathComponent()
        }
        return url
    }

    func touch(_ url: URL) {
        try! fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    /// `allowRealTmp` only lets the guard *judge* /tmp roots; tests must never create files there.
    func env(running: Set<String> = [], runner: (any CommandRunner)? = nil, allowRealTmp: Bool = false) -> DoCleanEnvironment {
        DoCleanEnvironment(home: home, tmpDir: tmp, externalBases: allowRealTmp ? [tmp, URL(fileURLWithPath: "/tmp"), URL(fileURLWithPath: "/private/tmp")] : [tmp],
                           probe: FixedAppStateProbe(running), runner: runner ?? FakeRunner())
    }

    func cleaner(_ env: DoCleanEnvironment, history: History? = nil, failing: Set<String> = []) -> Cleaner {
        Cleaner(environment: env, trasher: FakeTrasher(trash: trash, failing: failing), history: history)
    }
}

struct FakeTrasher: Trasher {
    let trash: URL
    var failing: Set<String> = []
    struct Boom: Error {}
    func trash(_ url: URL) throws {
        if failing.contains(url.lastPathComponent) { throw Boom() }
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock(); private var calls: [[String]] = []
    func add(_ c: [String]) { lock.lock(); calls.append(c); lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
}

/// Scripted command runner: `outputs["simctl list ..."]`; tools listed in `installed` exist.
struct FakeRunner: CommandRunner {
    var installed: Set<String> = []
    var outputs: [String: CommandOutput] = [:]   // key: args joined by space
    let log = CallLog()
    func locate(_ name: String) -> String? { installed.contains(name) ? "/fake/\(name)" : nil }
    func run(_ executable: String, _ args: [String]) -> CommandOutput {
        log.add([executable] + args)
        return outputs[args.joined(separator: " ")] ?? CommandOutput(status: 0, stdout: "")
    }
}

func loadCatalog() throws -> [Rule] { try RuleCatalog.load() }
func rule(_ id: String) throws -> Rule { try XCTUnwrap(loadCatalog().first { $0.id == id }, "rule \(id) missing") }
