import Foundation
import Observation

/// One concrete thing a rule found: a folder, a file, a model, or a command to run.
public struct ScanItem: Identifiable, Hashable, Codable, Sendable {
    /// The path, or `cmd:<ruleID>` for command items.
    public var id: String
    public var name: String
    public var path: String?
    public var bytes: Int64
    /// Newest modification inside the item at scan time. Cleaner refuses the item if this changed.
    public var fingerprint: Date?
    /// For display: last use / project activity when known (else the fingerprint).
    public var lastUsed: Date?
    public var detail: String?

    public var url: URL? { path.map { URL(fileURLWithPath: $0) } }
    public var isCommand: Bool { path == nil }
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    /// `.dmg`, `.pkg`, `.zip`, `.iso`: handy for the Downloads filters.
    public var isInstaller: Bool { ["dmg", "pkg", "zip", "iso", "mpkg"].contains(fileExtension) }

    public init(id: String, name: String, path: String?, bytes: Int64, fingerprint: Date? = nil,
                lastUsed: Date? = nil, detail: String? = nil) {
        self.id = id; self.name = name; self.path = path; self.bytes = bytes
        self.fingerprint = fingerprint; self.lastUsed = lastUsed ?? fingerprint; self.detail = detail
    }
}

/// What to clean: a rule and the scan items the user kept selected.
public struct CleanRequest: Sendable {
    public var rule: Rule
    public var items: [ScanItem]
    /// Set only by the tools (large files, duplicates, old files): Documents/Desktop/Pictures become allowed, Trash only.
    public var allowUserFolders: Bool
    public init(rule: Rule, items: [ScanItem], allowUserFolders: Bool = false) {
        self.rule = rule; self.items = items; self.allowUserFolders = allowUserFolders
    }
}

public enum RuleStatus: String, Codable, Sendable {
    /// Found something and it can be cleaned.
    case ready
    case empty
    /// Found something, but a required app is running ("close After Effects to free 46 GB").
    case blockedByRunningApp
    /// Tool not installed / not running (docker, brew, simctl).
    case unavailable
    /// A root failed the SafetyGuard; nothing was scanned.
    case rejected
}

public struct RuleResult: Identifiable, Sendable {
    public var rule: Rule
    public var items: [ScanItem]
    public var status: RuleStatus
    /// Running apps that block this rule (bundle ids).
    public var blockedBy: [String]
    /// Bytes deliberately left alone (e.g. the newest DeviceSupport).
    public var protectedBytes: Int64
    public var message: String?

    public var id: String { rule.id }
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var isCleanable: Bool { status == .ready && !items.isEmpty }

    public init(rule: Rule, items: [ScanItem] = [], status: RuleStatus = .ready, blockedBy: [String] = [],
                protectedBytes: Int64 = 0, message: String? = nil) {
        self.rule = rule; self.items = items; self.status = status; self.blockedBy = blockedBy
        self.protectedBytes = protectedBytes; self.message = message
    }
}

public struct CategoryGroup: Sendable { public var category: RuleCategory; public var results: [RuleResult]
    public var bytes: Int64 { results.reduce(0) { $0 + $1.bytes } } }
public struct TierGroup: Sendable { public var tier: Tier; public var categories: [CategoryGroup]
    public var bytes: Int64 { categories.reduce(0) { $0 + $1.bytes } } }

public struct ScanResult: Sendable {
    public var results: [RuleResult]
    public var date: Date
    public var cancelled: Bool

    public init(results: [RuleResult], date: Date = Date(), cancelled: Bool = false) {
        self.results = results; self.date = date; self.cancelled = cancelled
    }

    /// Everything found (blocked rules included).
    public var totalBytes: Int64 { results.reduce(0) { $0 + $1.bytes } }
    public func bytes(tier: Tier) -> Int64 { results.filter { $0.rule.tier == tier }.reduce(0) { $0 + $1.bytes } }
    /// Bytes that can be freed right now.
    public var cleanableBytes: Int64 { results.filter(\.isCleanable).reduce(0) { $0 + $1.bytes } }
    public var blockedBytes: Int64 { results.filter { $0.status == .blockedByRunningApp }.reduce(0) { $0 + $1.bytes } }

    public func result(id: String) -> RuleResult? { results.first { $0.id == id } }

    /// Results grouped tier → category, skipping empty ones, biggest first.
    public func grouped(includeEmpty: Bool = false) -> [TierGroup] {
        Tier.allCases.compactMap { tier in
            let ofTier = results.filter { $0.rule.tier == tier && (includeEmpty || !$0.items.isEmpty) }
            guard !ofTier.isEmpty else { return nil }
            let cats = RuleCategory.allCases.compactMap { cat -> CategoryGroup? in
                let rs = ofTier.filter { $0.rule.category == cat }.sorted { $0.bytes > $1.bytes }
                return rs.isEmpty ? nil : CategoryGroup(category: cat, results: rs)
            }
            return TierGroup(tier: tier, categories: cats)
        }
    }

    /// Builds the Cleaner input for the given rule ids (all items of each rule).
    public func requests(ruleIDs: Set<String>) -> [CleanRequest] {
        results.filter { ruleIDs.contains($0.id) && $0.isCleanable }.map { CleanRequest(rule: $0.rule, items: $0.items) }
    }
}

public enum ScanEvent: Sendable {
    case started(totalRules: Int)
    case ruleStarted(id: String)
    /// Running total of bytes found so far (monotonic; may slightly exceed the final total when items get filtered).
    case bytesFound(Int64)
    case ruleFinished(RuleResult)
    case finished(ScanResult)
}

/// Observable wrapper for SwiftUI: `model.start()`, bind to `bytesFound`, `results`, `finished`.
@MainActor @Observable
public final class ScanModel {
    public enum Phase: Sendable { case idle, scanning, done, cancelled }
    public private(set) var phase: Phase = .idle
    public private(set) var bytesFound: Int64 = 0
    public private(set) var completedRules = 0
    public private(set) var totalRules = 0
    public private(set) var currentRuleIDs: Set<String> = []
    /// Per-rule results as they arrive (cards fill up live).
    public private(set) var resultsByRule: [String: RuleResult] = [:]
    public private(set) var result: ScanResult?

    private var task: Task<Void, Never>?
    public init() {}

    public var progress: Double { totalRules == 0 ? 0 : Double(completedRules) / Double(totalRules) }

    public func start(rules: [Rule], environment: DoCleanEnvironment) {
        cancel()
        phase = .scanning; bytesFound = 0; completedRules = 0; totalRules = rules.count
        currentRuleIDs = []; resultsByRule = [:]; result = nil
        let stream = CleanScanner(environment: environment).events(rules: rules)
        task = Task { [weak self] in
            for await ev in stream {
                guard let self else { return }
                switch ev {
                case .started(let n): self.totalRules = n
                case .ruleStarted(let id): self.currentRuleIDs.insert(id)
                case .bytesFound(let b): self.bytesFound = b
                case .ruleFinished(let r):
                    self.currentRuleIDs.remove(r.id); self.completedRules += 1; self.resultsByRule[r.id] = r
                case .finished(let res): self.result = res; self.phase = res.cancelled ? .cancelled : .done
                }
            }
        }
    }

    public func cancel() {
        task?.cancel(); task = nil
        if phase == .scanning { phase = .cancelled }
    }
}
