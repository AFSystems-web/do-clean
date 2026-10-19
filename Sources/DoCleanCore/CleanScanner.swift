import Foundation

/// Thread-safe running total for `ScanEvent.bytesFound`.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    func add(_ n: Int64) -> Int64 { lock.lock(); defer { lock.unlock() }; total += n; return total }
}

public struct CleanScanner: Sendable {
    public let environment: DoCleanEnvironment
    public init(environment: DoCleanEnvironment) { self.environment = environment }

    // MARK: Public API

    /// Scans all rules in parallel. Cancel by cancelling the surrounding Task. Never modifies anything.
    public func scan(rules: [Rule], onEvent: (@Sendable (ScanEvent) -> Void)? = nil) async -> ScanResult {
        let rules = rules.filter { !environment.exclusions.excludes(rule: $0.id) }
        onEvent?(.started(totalRules: rules.count))
        let counter = ByteCounter()
        let env = environment
        var collected: [String: RuleResult] = [:]
        await withTaskGroup(of: RuleResult.self) { group in
            for rule in rules {
                group.addTask {
                    onEvent?(.ruleStarted(id: rule.id))
                    let r = await CleanScanner(environment: env).scan(rule: rule) { n in
                        onEvent?(.bytesFound(counter.add(n)))
                    }
                    onEvent?(.ruleFinished(r))
                    return r
                }
            }
            for await r in group { collected[r.id] = r }
        }
        let ordered = rules.compactMap { collected[$0.id] }
        let result = ScanResult(results: CleanScanner.dropOverlaps(ordered), date: environment.now(), cancelled: Task.isCancelled)
        onEvent?(.finished(result))
        return result
    }

    /// Event stream for UIs; terminating the stream cancels the scan.
    public func events(rules: [Rule]) -> AsyncStream<ScanEvent> {
        AsyncStream { cont in
            let task = Task {
                _ = await self.scan(rules: rules) { cont.yield($0) }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: One rule

    public func scan(rule: Rule, onBytes: (@Sendable (Int64) -> Void)? = nil) async -> RuleResult {
        let env = environment
        let guardrail = env.guardrail
        if env.exclusions.excludes(rule: rule.id) { return RuleResult(rule: rule, status: .empty, message: "excluded") }
        let roots = rule.roots.map(env.expand)

        for root in roots {
            do { try guardrail.checkRoot(root) } catch {
                return RuleResult(rule: rule, status: .rejected, message: "\(error)")
            }
        }
        var raw: Candidates
        switch rule.kind {
        case .standard: raw = Candidates(urls: CleanScanner.standardCandidates(rule: rule, roots: roots))
        case .deviceSupport: raw = CleanScanner.deviceSupportCandidates(rule: rule, roots: roots, env: env)
        case .huggingface: raw = Candidates(urls: CleanScanner.huggingFaceCandidates(roots: roots))
        case .fcpRender: raw = Candidates(urls: CleanScanner.fcpRenderCandidates(roots: roots))
        case .nodeModules: raw = CleanScanner.nodeModuleCandidates(rule: rule, roots: roots, env: env)
        case .simctlUnavailable, .simctlEraseAll, .brewCleanup, .dockerPrune:
            return await CleanScanner.commandRule(rule: rule, env: env, onBytes: onBytes)
        }

        if Task.isCancelled { return RuleResult(rule: rule, status: .empty) }
        if !env.exclusions.isEmpty { raw.urls = raw.urls.filter { !env.exclusions.blocks($0) } }
        let items = await measureAll(raw.urls, activity: raw.activity, rule: rule, onBytes: onBytes)
        return finalize(rule: rule, items: items, protectedBytes: raw.protectedBytes, note: raw.note)
    }

    /// Turns measured items into a RuleResult: age filter, keepNewest, app-running check.
    func finalize(rule: Rule, items measured: [ScanItem], protectedBytes: Int64 = 0, note: String? = nil) -> RuleResult {
        var items = measured
        if rule.minAgeDays > 0 {
            let limit = environment.now().addingTimeInterval(-Double(rule.minAgeDays) * 86_400)
            items = items.filter { ($0.lastUsed ?? $0.fingerprint ?? .distantFuture) < limit }
        }
        var protected = protectedBytes
        if rule.keepNewest > 0 {
            let sorted = items.sorted { ($0.fingerprint ?? .distantPast) > ($1.fingerprint ?? .distantPast) }
            protected += sorted.prefix(rule.keepNewest).reduce(0) { $0 + $1.bytes }
            items = Array(sorted.dropFirst(rule.keepNewest))
        }
        items.sort { $0.bytes > $1.bytes }
        items = items.filter { $0.bytes > 0 || $0.isCommand }
        guard !items.isEmpty else { return RuleResult(rule: rule, status: .empty, protectedBytes: protected, message: note) }
        let blockers = environment.probe.runningApps(matching: rule.requiresAppClosed)
        return RuleResult(rule: rule, items: items, status: blockers.isEmpty ? .ready : .blockedByRunningApp,
                          blockedBy: blockers, protectedBytes: protected, message: note)
    }

    // MARK: Measuring

    func measureAll(_ urls: [URL], activity: [String: Date], rule: Rule, onBytes: (@Sendable (Int64) -> Void)?) async -> [ScanItem] {
        await withTaskGroup(of: ScanItem?.self) { group in
            var running = 0
            var out: [ScanItem] = []
            func collect(_ i: ScanItem?) { if let i { out.append(i) } }
            for url in urls {
                if running >= 8 { if let next = await group.next() { collect(next) }; running -= 1 }
                group.addTask {
                    if Task.isCancelled { return nil }
                    let m = FileMeasure.measure(url, onBytes: onBytes)
                    if Task.isCancelled { return nil }
                    return ScanItem(id: url.path, name: CleanScanner.displayName(url, rule: rule), path: url.path, bytes: m.bytes,
                                    fingerprint: m.newest, lastUsed: activity[url.path] ?? m.newest, detail: CleanScanner.detail(url, rule: rule))
                }
                running += 1
            }
            for await i in group { collect(i) }
            return out
        }
    }

    static func displayName(_ url: URL, rule: Rule) -> String {
        let n = url.lastPathComponent
        guard rule.kind == .huggingface else { return n }
        for p in ["models--", "datasets--", "spaces--"] where n.hasPrefix(p) {
            return n.dropFirst(p.count).replacingOccurrences(of: "--", with: "/")
        }
        return n
    }

    static func detail(_ url: URL, rule: Rule) -> String? {
        guard rule.kind == .huggingface else { return nil }
        let n = url.lastPathComponent
        if n.hasPrefix("models--") { return "model" }
        if n.hasPrefix("datasets--") { return "dataset" }
        if n.hasPrefix("spaces--") { return "space" }
        return nil
    }

    // MARK: Overlap protection

    /// When two rules found the same path, the earlier (higher priority) rule keeps it.
    /// Items that contain, or sit inside, an already claimed path are dropped, so bytes are never counted twice
    /// and a generic rule can never delete something a specific rule owns.
    static func dropOverlaps(_ results: [RuleResult]) -> [RuleResult] {
        var claimed: [String] = []
        return results.map { r in
            guard r.status != .rejected else { return r }
            var kept: [ScanItem] = []
            for item in r.items {
                guard let p = item.path else { kept.append(item); continue }
                let overlaps = claimed.contains { SafetyGuard.isInside(p, of: $0) || SafetyGuard.isInside($0, of: p) }
                if !overlaps { kept.append(item) }
            }
            claimed.append(contentsOf: kept.compactMap(\.path))
            var out = r
            out.items = kept
            if kept.isEmpty, r.status == .ready || r.status == .blockedByRunningApp { out.status = .empty }
            return out
        }
    }
}

struct Candidates {
    var urls: [URL]
    var activity: [String: Date] = [:]
    var protectedBytes: Int64 = 0
    var note: String?
}
