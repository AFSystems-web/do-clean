import Foundation

public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var ruleID: String
    public var bytes: Int64
    public var itemCount: Int
    public var method: DeletionMethod

    public init(id: UUID = UUID(), date: Date, ruleID: String, bytes: Int64, itemCount: Int, method: DeletionMethod) {
        self.id = id; self.date = date; self.ruleID = ruleID; self.bytes = bytes; self.itemCount = itemCount; self.method = method
    }
}

/// "Freed so far" log, a JSON file in Application Support. Dry runs are never recorded.
public final class History: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/do clean/history.json")
    }

    public func entries() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    public func append(_ new: [HistoryEntry]) throws {
        guard !new.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let all = load() + new
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(all).write(to: fileURL, options: .atomic)
    }

    public var totalFreed: Int64 { entries().reduce(0) { $0 + $1.bytes } }

    /// Bytes freed per calendar day, oldest first (for the chart).
    public func freedByDay(calendar: Calendar = .current) -> [(day: Date, bytes: Int64)] {
        var sums: [Date: Int64] = [:]
        for e in entries() { sums[calendar.startOfDay(for: e.date), default: 0] += e.bytes }
        return sums.map { (day: $0.key, bytes: $0.value) }.sorted { $0.day < $1.day }
    }

    private func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([HistoryEntry].self, from: data)) ?? []
    }
}
