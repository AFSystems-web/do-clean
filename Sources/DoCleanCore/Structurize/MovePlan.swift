import Foundation

public enum SkipReason: String, Codable, Sendable {
    case hidden, symlink, bundle, busy, iCloudPlaceholder, partialDownload, excluded, forbidden
    /// A project folder that this preset does not move (it stays whole and untouched).
    case projectUnit
    /// A loose project file (.prproj, .aep, .blend…): moving it alone would break media links.
    case projectFile
    case alreadyInPlace, noRule, targetBlocked, changed, outsideSource
}

public struct SkippedEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var reason: SkipReason
    public var detail: String?
}

public struct PlannedMove: Codable, Identifiable, Hashable, Sendable {
    public var id: String { source }
    public var source: String
    public var destination: String
    /// The source folder chosen by the user; nothing is ever moved outside of it.
    public var root: String
    public var name: String
    public var isDirectory: Bool
    /// A project folder moved as one piece.
    public var isUnit: Bool
    public var bytes: Int64
    public var modified: Date?
    public var ruleName: String
    public var destinationName: String { (destination as NSString).lastPathComponent }
    /// Destination folder relative to `root`.
    public var targetFolder: String {
        let rel = String(((destination as NSString).deletingLastPathComponent).dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel
    }
}

/// A node of the "after" tree.
public struct PlanTreeNode: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isFolder: Bool
    /// Moved items inside (or 1 for a file/unit).
    public var count: Int
    public var bytes: Int64
    public var children: [PlanTreeNode]
    public var move: PlannedMove?
}

public struct MovePlan: Identifiable, Sendable {
    public var id = UUID()
    public var presetID: String
    public var presetTitle: L10n
    public var sources: [String]
    public var moves: [PlannedMove]
    public var skipped: [SkippedEntry]
    /// Folders that will be created (absolute paths, shallow first).
    public var newFolders: [String]
    public var date = Date()

    public var count: Int { moves.count }
    public var bytes: Int64 { moves.reduce(0) { $0 + $1.bytes } }
    public var isEmpty: Bool { moves.isEmpty && newFolders.isEmpty }

    public func skippedCount(_ reason: SkipReason) -> Int { skipped.filter { $0.reason == reason }.count }

    /// Counters per top-level target folder, biggest first: ("Видео", 12, bytes).
    public func summary() -> [(folder: String, count: Int, bytes: Int64)] {
        var d: [String: (Int, Int64)] = [:]
        for m in moves {
            let top = m.targetFolder.split(separator: "/").first.map(String.init) ?? "."
            let v = d[top] ?? (0, 0)
            d[top] = (v.0 + 1, v.1 + m.bytes)
        }
        return d.map { (folder: $0.key, count: $0.value.0, bytes: $0.value.1) }.sorted { $0.bytes > $1.bytes }
    }

    /// "After" trees, one per source folder: folders with counters, files/project units as leaves.
    public var afterTree: [PlanTreeNode] {
        sources.map { root in
            let mine = moves.filter { $0.root == root }
            var top = PlanTreeNode(id: root, name: (root as NSString).lastPathComponent, isFolder: true, count: 0, bytes: 0, children: [], move: nil)
            for m in mine { Self.insert(m, into: &top, components: m.targetFolder.split(separator: "/").map(String.init), path: root) }
            for f in newFolders where f.hasPrefix(root + "/") {
                Self.ensure(&top, components: String(f.dropFirst(root.count + 1)).split(separator: "/").map(String.init), path: root)
            }
            Self.sort(&top)
            return top
        }
    }

    private static func ensure(_ node: inout PlanTreeNode, components: [String], path: String) {
        guard let first = components.first else { return }
        let childPath = path + "/" + first
        if let i = node.children.firstIndex(where: { $0.id == childPath }) {
            ensure(&node.children[i], components: Array(components.dropFirst()), path: childPath)
        } else {
            var c = PlanTreeNode(id: childPath, name: first, isFolder: true, count: 0, bytes: 0, children: [], move: nil)
            ensure(&c, components: Array(components.dropFirst()), path: childPath)
            node.children.append(c)
        }
    }

    private static func insert(_ m: PlannedMove, into node: inout PlanTreeNode, components: [String], path: String) {
        node.count += 1; node.bytes += m.bytes
        guard let first = components.first else {
            node.children.append(PlanTreeNode(id: m.destination, name: m.destinationName, isFolder: m.isDirectory, count: 1, bytes: m.bytes, children: [], move: m))
            return
        }
        let childPath = path + "/" + first
        if let i = node.children.firstIndex(where: { $0.id == childPath }) {
            insert(m, into: &node.children[i], components: Array(components.dropFirst()), path: childPath)
        } else {
            var c = PlanTreeNode(id: childPath, name: first, isFolder: true, count: 0, bytes: 0, children: [], move: nil)
            insert(m, into: &c, components: Array(components.dropFirst()), path: childPath)
            node.children.append(c)
        }
    }

    private static func sort(_ n: inout PlanTreeNode) {
        for i in n.children.indices { sort(&n.children[i]) }
        n.children.sort { a, b in a.move == nil && b.move != nil ? true : (a.move != nil && b.move == nil ? false : a.name.localizedStandardCompare(b.name) == .orderedAscending) }
    }
}

public enum StructurizeError: Error, CustomStringConvertible {
    case sourceMissing(String)
    case sourceNotAllowed(String, String)
    case presetInvalid(String)
    public var description: String {
        switch self {
        case .sourceMissing(let p): "source folder not found: \(p)"
        case .sourceNotAllowed(let p, let why): "source folder not allowed (\(why)): \(p)"
        case .presetInvalid(let why): "invalid preset: \(why)"
        }
    }
}
