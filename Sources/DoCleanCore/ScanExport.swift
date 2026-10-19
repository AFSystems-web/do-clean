import Foundation

/// Stable JSON shape for `doclean scan --json` (also handy for tests and bug reports).
public struct ScanExport: Codable, Sendable {
    public struct Totals: Codable, Sendable {
        public var green: Int64, yellow: Int64, red: Int64, all: Int64, cleanable: Int64, blocked: Int64
    }
    public struct ItemDTO: Codable, Sendable {
        public var name: String; public var path: String?; public var bytes: Int64; public var lastUsed: Date?
    }
    public struct RuleDTO: Codable, Sendable {
        public var id: String; public var title: String; public var tier: Tier; public var category: RuleCategory
        public var palette: String; public var status: RuleStatus; public var bytes: Int64; public var protectedBytes: Int64
        public var blockedBy: [String]; public var message: String?; public var items: [ItemDTO]
    }
    public var date: Date
    public var totals: Totals
    public var rules: [RuleDTO]

    public init(_ r: ScanResult, includeItems: Bool = true) {
        date = r.date
        totals = Totals(green: r.bytes(tier: .green), yellow: r.bytes(tier: .yellow), red: r.bytes(tier: .red),
                        all: r.totalBytes, cleanable: r.cleanableBytes, blocked: r.blockedBytes)
        rules = r.results.map { res in
            RuleDTO(id: res.id, title: res.rule.title.en, tier: res.rule.tier, category: res.rule.category,
                    palette: res.rule.palette, status: res.status, bytes: res.bytes, protectedBytes: res.protectedBytes,
                    blockedBy: res.blockedBy, message: res.message,
                    items: includeItems ? res.items.map { ItemDTO(name: $0.name, path: $0.path, bytes: $0.bytes, lastUsed: $0.lastUsed) } : [])
        }
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }
}

public func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: b)
}
