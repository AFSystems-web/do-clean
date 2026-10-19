import Foundation

/// Result of walking one file or folder.
public struct Measure: Sendable {
    public var bytes: Int64 = 0
    /// Newest modification date of anything inside (the item itself included). Used as the "changed since scan" fingerprint.
    public var newest: Date?
    public var files: Int = 0
}

enum FileMeasure {
    static let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey,
    ]

    static func allocated(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
    }

    /// Real on-disk size (`totalFileAllocatedSize`), never following symlinks. Honors task cancellation.
    /// `onBytes` receives increments roughly every 2000 files so the UI can animate on huge folders.
    static func measure(_ url: URL, onBytes: ((Int64) -> Void)? = nil) -> Measure {
        var m = Measure()
        let rv = try? url.resourceValues(forKeys: Set(keys))
        m.newest = rv?.contentModificationDate
        guard let rv else { return m }
        if rv.isDirectory != true {
            m.bytes = allocated(rv); m.files = 1
            onBytes?(m.bytes)
            return m
        }
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return m }
        var pending: Int64 = 0
        var n = 0
        for case let f as URL in en {
            if Task.isCancelled { break }
            guard let v = try? f.resourceValues(forKeys: Set(keys)) else { continue }
            if let d = v.contentModificationDate, d > (m.newest ?? .distantPast) { m.newest = d }
            if v.isDirectory != true {
                let b = allocated(v)
                m.bytes += b; pending += b; m.files += 1; n += 1
                if n % 2000 == 0 { onBytes?(pending); pending = 0 }
            }
        }
        if pending > 0 { onBytes?(pending) }
        return m
    }

    /// Cheap re-check used right before deletion.
    static func fingerprint(_ url: URL) -> Date? { measure(url).newest }
}
