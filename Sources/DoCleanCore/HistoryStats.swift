import Foundation

/// Aggregates for the History screen chart.
public struct HistoryStats: Sendable {
    public struct Bucket: Sendable, Identifiable, Equatable {
        public var id: Date { start }
        public var start: Date
        public var bytes: Int64
    }

    public let entries: [HistoryEntry]
    public let categoryOf: [String: RuleCategory]
    public let calendar: Calendar

    public init(entries: [HistoryEntry], rules: [Rule], calendar: Calendar = .current) {
        self.entries = entries; self.calendar = calendar
        categoryOf = Dictionary(rules.map { ($0.id, $0.category) }, uniquingKeysWith: { a, _ in a })
    }

    public init(history: History, rules: [Rule], calendar: Calendar = .current) {
        self.init(entries: history.entries(), rules: rules, calendar: calendar)
    }

    public var totalFreed: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    public var cleanupCount: Int { entries.count }
    public var lastCleanup: Date? { entries.map(\.date).max() }
    public var biggest: HistoryEntry? { entries.max { $0.bytes < $1.bytes } }

    /// Tool entries ("tool-*") are personal files; unknown rule ids fall back to `.system`.
    public func category(of entry: HistoryEntry) -> RuleCategory {
        categoryOf[entry.ruleID] ?? (entry.ruleID.hasPrefix("tool-") ? .personal : .system)
    }

    public func byCategory() -> [RuleCategory: Int64] {
        var out: [RuleCategory: Int64] = [:]
        for e in entries { out[category(of: e), default: 0] += e.bytes }
        return out
    }

    public func byRule() -> [(ruleID: String, bytes: Int64)] {
        Dictionary(grouping: entries, by: \.ruleID).map { ($0.key, $0.value.reduce(0) { $0 + $1.bytes }) }.sorted { $0.1 > $1.1 }
    }

    /// The last `days` days ending today, zero-filled, oldest first.
    public func perDay(last days: Int = 30, now: Date = Date()) -> [Bucket] {
        let today = calendar.startOfDay(for: now)
        var sums: [Date: Int64] = [:]
        for e in entries { sums[calendar.startOfDay(for: e.date), default: 0] += e.bytes }
        return (0..<max(0, days)).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { Bucket(start: $0, bytes: sums[$0] ?? 0) }
        }
    }

    /// The last `weeks` calendar weeks ending with the current one, zero-filled, oldest first.
    public func perWeek(last weeks: Int = 12, now: Date = Date()) -> [Bucket] {
        func weekStart(_ d: Date) -> Date { calendar.dateInterval(of: .weekOfYear, for: d)?.start ?? calendar.startOfDay(for: d) }
        var sums: [Date: Int64] = [:]
        for e in entries { sums[weekStart(e.date), default: 0] += e.bytes }
        let thisWeek = weekStart(now)
        return (0..<max(0, weeks)).reversed().compactMap { back in
            calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek).map { Bucket(start: $0, bytes: sums[$0] ?? 0) }
        }
    }

    /// Freed since `date` (e.g. "this month").
    public func freed(since date: Date) -> Int64 { entries.filter { $0.date >= date }.reduce(0) { $0 + $1.bytes } }
}
