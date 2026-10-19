import Foundation
import AppKit

/// Everything the engine needs to know about the machine. Tests build one over a temp dir.
public struct DoCleanEnvironment: Sendable {
    public var home: URL
    public var tmpDir: URL
    /// Extra bases (besides home) rules may live in: `/tmp`, `$TMPDIR`.
    public var externalBases: [URL]
    public var probe: any AppStateProbe
    public var runner: any CommandRunner
    public var now: @Sendable () -> Date
    public var exclusions: Exclusions

    public init(home: URL, tmpDir: URL, externalBases: [URL]? = nil,
                probe: any AppStateProbe = SystemAppStateProbe(),
                runner: any CommandRunner = ProcessCommandRunner(),
                now: @escaping @Sendable () -> Date = { Date() },
                exclusions: Exclusions = .none) {
        self.home = home
        self.tmpDir = tmpDir
        self.externalBases = externalBases ?? [tmpDir]
        self.probe = probe; self.runner = runner; self.now = now; self.exclusions = exclusions
    }

    /// The real machine. Only the CLI/app call this.
    /// `home` overrides the home folder (CLI `--home`, used to try things on a fake folder).
    public static func live(home: URL? = nil) -> DoCleanEnvironment {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return DoCleanEnvironment(
            home: home ?? FileManager.default.homeDirectoryForCurrentUser,
            tmpDir: tmp,
            externalBases: [tmp, URL(fileURLWithPath: "/tmp"), URL(fileURLWithPath: "/private/tmp")])
    }

    /// Expands `~` and `$TMPDIR`.
    public func expand(_ path: String) -> URL {
        var p = path
        if p == "~" || p.hasPrefix("~/") { p = home.path + p.dropFirst(1) }
        if p.hasPrefix("$TMPDIR") { p = tmpDir.path + p.dropFirst("$TMPDIR".count) }
        return URL(fileURLWithPath: p)
    }

    public var guardrail: SafetyGuard { SafetyGuard(home: home, externalBases: externalBases) }
}

// MARK: - Running apps

public protocol AppStateProbe: Sendable {
    func runningBundleIDs() -> Set<String>
}

public extension AppStateProbe {
    /// Which of `patterns` (bundle ids, trailing `*` = prefix) are running right now.
    func runningApps(matching patterns: [String]) -> [String] {
        let running = runningBundleIDs()
        var hit: [String] = []
        for p in patterns {
            let matches = p.hasSuffix("*") ? running.filter { $0.hasPrefix(String(p.dropLast())) } : running.filter { $0 == p }
            hit.append(contentsOf: matches.sorted())
        }
        return hit
    }
}

public struct SystemAppStateProbe: AppStateProbe {
    public init() {}
    public func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

/// Test double.
public struct FixedAppStateProbe: AppStateProbe {
    public var running: Set<String>
    public init(_ running: Set<String> = []) { self.running = running }
    public func runningBundleIDs() -> Set<String> { running }
}

// MARK: - Commands

public struct CommandOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public init(status: Int32, stdout: String) { self.status = status; self.stdout = stdout }
}

public protocol CommandRunner: Sendable {
    /// Finds an executable on the usual dev PATH. nil = not installed.
    func locate(_ name: String) -> String?
    func run(_ executable: String, _ args: [String]) -> CommandOutput
}

public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func locate(_ name: String) -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/usr/sbin", "/bin", "/Applications/Docker.app/Contents/Resources/bin"]
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func run(_ executable: String, _ args: [String]) -> CommandOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return CommandOutput(status: -1, stdout: "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return CommandOutput(status: p.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }
}
