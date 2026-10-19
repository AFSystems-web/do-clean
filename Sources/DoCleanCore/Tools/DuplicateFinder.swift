import Foundation
import CryptoKit

public struct DuplicateGroup: Identifiable, Sendable {
    public var id: String { sha256 }
    public var sha256: String
    /// Logical size of each copy.
    public var size: Int64
    public var files: [ToolFile]
    /// Suggested file to keep (index into `files`).
    public var keepIndex: Int

    public var keep: ToolFile { files[keepIndex] }
    public var removable: [ToolFile] { files.enumerated().filter { $0.offset != keepIndex }.map(\.element) }
    /// What is freed by trashing every copy but the one kept.
    public var reclaimableBytes: Int64 { removable.reduce(0) { $0 + $1.bytes } }

    /// Request that trashes `toRemove`, refusing to ever remove every copy: the kept file is always dropped from the request.
    public func cleanRequest(removing toRemove: [ToolFile]? = nil, keeping kept: ToolFile? = nil) -> CleanRequest {
        let keepPath = (kept ?? keep).path
        let pick = (toRemove ?? removable).filter { $0.path != keepPath && files.contains($0) }
        return ToolCleanup.request(id: "tool-duplicates", title: L10n(ru: "Дубликаты", en: "Duplicates"), files: pick)
    }
}

/// size → first+last 64 KB → full SHA-256.
public struct DuplicateFinder: Sendable {
    public var environment: DoCleanEnvironment
    public var minBytes: Int64
    public var dates: any FileDateProvider
    static let sample = 64 * 1024

    public init(environment: DoCleanEnvironment, minBytes: Int64 = 1_000_000, dates: any FileDateProvider = SpotlightFileDates()) {
        self.environment = environment; self.minBytes = minBytes; self.dates = dates
    }

    public func find(progress: ToolProgressHandler? = nil) async -> [DuplicateGroup] {
        var entries: [HomeWalker.Entry] = []
        HomeWalker.walk(home: environment.home, minAllocated: max(1, minBytes), exclusions: environment.exclusions, progress: progress, phase: "scan") { entries.append($0) }
        return await group(entries, progress: progress)
    }

    func group(_ all: [HomeWalker.Entry], progress: ToolProgressHandler?) async -> [DuplicateGroup] {
        let guardrail = environment.guardrail.relaxedForTools()
        // Drop hard links of one file (same inode) and files the guard would refuse.
        var seenIDs = Set<String>()
        let entries = all.filter { e in
            if let id = e.identifier, !seenIDs.insert(id).inserted { return false }
            return e.logical > 0 && (try? guardrail.checkPath(e.url)) != nil
        }
        let bySize = Dictionary(grouping: entries, by: \.logical).filter { $0.value.count > 1 }
        let total = bySize.values.reduce(0) { $0 + $1.count }
        var done = 0
        var result: [DuplicateGroup] = []
        for (size, sameSize) in bySize.sorted(by: { $0.key > $1.key }) {
            if Task.isCancelled { return [] }
            var byQuick: [String: [HomeWalker.Entry]] = [:]
            for e in sameSize {
                if let h = Self.quickHash(e.url, size: size) { byQuick[h, default: []].append(e) }
                done += 1
                progress?(ToolProgress(filesVisited: done, bytesFound: 0, phase: "quick-hash \(done)/\(total)", currentPath: e.url.path))
            }
            for (_, candidates) in byQuick where candidates.count > 1 {
                var byFull: [String: [HomeWalker.Entry]] = [:]
                for e in candidates {
                    if Task.isCancelled { return [] }
                    if let h = Self.fullHash(e.url) { byFull[h, default: []].append(e) }
                }
                for (hash, same) in byFull where same.count > 1 {
                    let files = same.map { HomeWalker.toolFile($0, dates: dates) }
                    result.append(DuplicateGroup(sha256: hash, size: size, files: files, keepIndex: Self.suggestKeep(files, home: environment.home)))
                }
            }
        }
        return result.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Prefer a copy outside Downloads; among those, the oldest (by modified date); ties by shortest path.
    public static func suggestKeep(_ files: [ToolFile], home: URL) -> Int {
        let downloads = home.appendingPathComponent("Downloads").path + "/"
        let ranked = files.enumerated().sorted { a, b in
            let ad = a.element.path.hasPrefix(downloads), bd = b.element.path.hasPrefix(downloads)
            if ad != bd { return !ad }
            let am = a.element.modified ?? .distantFuture, bm = b.element.modified ?? .distantFuture
            if am != bm { return am < bm }
            return a.element.path.count < b.element.path.count
        }
        return ranked[0].offset
    }

    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// First + last 64 KB (the whole file if it is small).
    static func quickHash(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        guard let head = try? h.read(upToCount: sample) else { return nil }
        hasher.update(data: head)
        if size > Int64(sample) * 2 {
            guard (try? h.seek(toOffset: UInt64(size) - UInt64(sample))) != nil, let tail = try? h.read(upToCount: sample) else { return nil }
            hasher.update(data: tail)
        }
        return hex(hasher.finalize())
    }

    static func fullHash(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while !Task.isCancelled {
            do {
                // read(upToCount:) returns nil (or empty) at end of file and throws on real errors.
                guard let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty else { return hex(hasher.finalize()) }
                hasher.update(data: chunk)
            } catch { return nil }
        }
        return nil
    }
}
