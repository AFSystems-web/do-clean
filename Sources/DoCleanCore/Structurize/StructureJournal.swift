import Foundation

public struct JournalMove: Codable, Hashable, Sendable {
    public var from: String
    public var to: String
    public var root: String
    public var isDirectory: Bool
    public var bytes: Int64
}

/// Everything one Structurize run did, enough to undo it.
public struct StructureJournal: Identifiable, Sendable {
    public var id: String
    public var date: Date
    public var presetTitle: String
    public var sources: [String]
    /// Folders created by the run, in creation order.
    public var folders: [String]
    public var moves: [JournalMove]
    public var finished: Bool
    public var undoneAt: Date?
    public var isUndone: Bool { undoneAt != nil }
    public var bytes: Int64 { moves.reduce(0) { $0 + $1.bytes } }
}

/// One JSON object per line (JSONL), appended before each move, so a crash in the middle can still be undone.
struct JournalLine: Codable {
    var type: String                      // begin | folder | move | end | undo
    var id: String?
    var date: Date?
    var presetTitle: String?
    var sources: [String]?
    var path: String?
    var move: JournalMove?
}

public final class JournalWriter: @unchecked Sendable {
    let handle: FileHandle
    let lock = NSLock()
    var pending = 0
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ line: JournalLine, sync: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        var data = try Self.encoder.encode(line); data.append(0x0A)
        try handle.write(contentsOf: data)
        pending += 1
        if sync || pending >= 50 { try handle.synchronize(); pending = 0 }
    }
    func close() { try? handle.synchronize(); try? handle.close() }
}

/// `~/Library/Application Support/do clean/structurize/<id>.jsonl`
public struct JournalStore: Sendable {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }
    public static func `default`(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> JournalStore {
        JournalStore(directory: home.appendingPathComponent("Library/Application Support/do clean/structurize", isDirectory: true))
    }

    func url(_ id: String) -> URL { directory.appendingPathComponent("\(id).jsonl") }

    func begin(id: String, date: Date, presetTitle: String, sources: [String]) throws -> JournalWriter {
        let w = try JournalWriter(url: url(id))
        try w.write(JournalLine(type: "begin", id: id, date: date, presetTitle: presetTitle, sources: sources), sync: true)
        return w
    }

    func appendUndo(_ id: String, date: Date) throws {
        let w = try JournalWriterAppend(url: url(id))
        try w.write(JournalLine(type: "undo", date: date), sync: true)
        w.close()
    }

    public func load(id: String) -> StructureJournal? {
        guard let text = try? String(contentsOf: url(id), encoding: .utf8) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var j = StructureJournal(id: id, date: Date(), presetTitle: "", sources: [], folders: [], moves: [], finished: false, undoneAt: nil)
        var sawBegin = false
        for raw in text.split(separator: "\n") {
            guard let line = try? dec.decode(JournalLine.self, from: Data(raw.utf8)) else { continue }   // a half-written last line is ignored
            switch line.type {
            case "begin": sawBegin = true; j.date = line.date ?? j.date; j.presetTitle = line.presetTitle ?? ""; j.sources = line.sources ?? []
            case "folder": if let p = line.path { j.folders.append(p) }
            case "move": if let m = line.move { j.moves.append(m) }
            case "end": j.finished = true
            case "undo": j.undoneAt = line.date ?? Date()
            default: break
            }
        }
        return sawBegin ? j : nil
    }

    /// Newest first.
    public func list() -> [StructureJournal] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.compactMap { load(id: $0.deletingPathExtension().lastPathComponent) }.sorted { $0.date > $1.date }
    }

    /// The latest run that can still be undone.
    public func latestUndoable() -> StructureJournal? { list().first { !$0.isUndone && !$0.moves.isEmpty || (!$0.isUndone && !$0.folders.isEmpty) } }
}

final class JournalWriterAppend: @unchecked Sendable {
    let handle: FileHandle
    init(url: URL) throws { handle = try FileHandle(forWritingTo: url); try handle.seekToEnd() }
    func write(_ line: JournalLine, sync: Bool) throws {
        var data = try JournalWriter.encoder.encode(line); data.append(0x0A)
        try handle.write(contentsOf: data); if sync { try handle.synchronize() }
    }
    func close() { try? handle.close() }
}
