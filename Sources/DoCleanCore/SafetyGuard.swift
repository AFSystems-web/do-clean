import Foundation

public enum SafetyViolation: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case notInAllowedBase(String)
    case forbidden(String)
    case coversForbidden(String)
    case outsideRoot(String)
    case symlinkEscape(String)
    case modifiedAfterScan(String)
    case commandNotAllowed([String])
    case isRootItself(String)

    public var description: String {
        switch self {
        case .missing(let p): "missing: \(p)"
        case .notInAllowedBase(let p): "not in home or temp: \(p)"
        case .forbidden(let p): "forbidden path: \(p)"
        case .coversForbidden(let p): "would contain a forbidden path: \(p)"
        case .outsideRoot(let p): "outside the rule root: \(p)"
        case .symlinkEscape(let p): "symlink leads outside the root: \(p)"
        case .modifiedAfterScan(let p): "changed after the scan: \(p)"
        case .commandNotAllowed(let c): "command not allowed: \(c.joined(separator: " "))"
        case .isRootItself(let p): "refusing to remove a root itself: \(p)"
        }
    }
}

/// Last line of defence (SPEC §5). Every path passes through here before it is touched.
/// The forbidden list is hard-coded on purpose: it is not configurable.
public struct SafetyGuard: Sendable {
    public let home: URL
    public let externalBases: [URL]
    /// Tools mode: Documents, Desktop and Pictures may be touched (preview + Trash only). Everything else stays forbidden.
    public let allowsUserFolders: Bool

    public init(home: URL, externalBases: [URL] = [], allowsUserFolders: Bool = false) {
        self.home = home
        self.externalBases = externalBases
        self.allowsUserFolders = allowsUserFolders
    }

    static let userFolders: Set<String> = ["Documents", "Desktop", "Pictures"]

    /// Same guard, but Documents/Desktop/Pictures are allowed. Only the Cleaner hands this out, for Trash-only tool requests.
    public func relaxedForTools() -> SafetyGuard {
        SafetyGuard(home: home, externalBases: externalBases, allowsUserFolders: true)
    }

    var activeForbiddenHomeRelative: [String] {
        allowsUserFolders ? Self.forbiddenHomeRelative.filter { !Self.userFolders.contains($0) } : Self.forbiddenHomeRelative
    }

    /// Paths below home that are never touched (nor anything containing them).
    static let forbiddenHomeRelative: [String] = [
        "Documents", "Desktop", "Pictures", "Library/Mobile Documents",
        "Library/Keychains", "Library/Application Support", "Library/Preferences", "Library/Safari",
        "Library/Cookies", "Library/Mail", "Library/Messages", "Library/Photos", "Library/Group Containers",
        "Library/Accounts", "Library/Calendars", "Library/Containers/com.apple.Notes",
        ".ssh", ".gnupg", ".aws", ".config", ".kube", ".docker/config.json", ".zshrc", ".gitconfig",
        "Applications", "Public", "Music",
    ]

    /// Narrow caches that live inside a forbidden folder and are explicitly allowed.
    static let allowedInsideForbidden: [String] = [
        "Library/Application Support/Adobe/Common/Media Cache Files",
        "Library/Application Support/Adobe/Common/Media Cache",
        "Library/Application Support/Adobe/Common/Peak Files",
    ]

    static let forbiddenAbsolute: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/Library", "/Applications", "/private/etc", "/etc",
        "/private/var/db", "/private/var/root", "/Users", "/Volumes", "/opt", "/var/db",
    ]

    /// Allowed external bases may live under a forbidden absolute (e.g. none today), so only
    /// these exact exceptions are subtracted.
    static let pathComponentDenylist: [String] = [".photoslibrary", ".keychain", ".keychain-db", ".fcpbundle/Original Media"]

    static let allowedCommands: [[String]] = [
        ["xcrun", "simctl", "delete", "unavailable"],
        ["xcrun", "simctl", "erase", "all"],
        ["brew", "cleanup", "--prune=all"],
        ["docker", "system", "prune", "-f"],
    ]

    // MARK: Path helpers

    /// Resolves symlinks of the longest existing prefix, so not-yet-existing paths still compare right.
    static func canonical(_ url: URL) -> String {
        var rest: [String] = []
        var p = url.standardizedFileURL.path
        while p.count > 1, access(p, F_OK) != 0 { rest.append((p as NSString).lastPathComponent); p = (p as NSString).deletingLastPathComponent }
        var base: String
        if let r = realpath(p, nil) { base = String(cString: r); free(r) } else { base = p }
        for r in rest.reversed() { base += (base == "/" ? "" : "/") + r }
        return base
    }

    static func isInside(_ child: String, of parent: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private var forbiddenPaths: [String] {
        let h = Self.canonical(home)
        return Self.forbiddenHomeRelative.map { h + "/" + $0 } + Self.forbiddenAbsolute.map { Self.canonical(URL(fileURLWithPath: $0)) }
    }
    private var exceptions: [String] {
        let h = Self.canonical(home)
        return Self.allowedInsideForbidden.map { h + "/" + $0 }
    }
    private var bases: [String] { ([home] + externalBases).map(Self.canonical) }

    // MARK: Checks

    /// Is this path alone acceptable (allowed base, not forbidden, not covering a forbidden one)?
    public func checkPath(_ url: URL) throws {
        let p = Self.canonical(url)
        let h = Self.canonical(home)
        guard bases.contains(where: { Self.isInside(p, of: $0) }) else { throw SafetyViolation.notInAllowedBase(p) }
        if p == h { throw SafetyViolation.forbidden(p) }
        for d in Self.pathComponentDenylist where p.contains(d) { throw SafetyViolation.forbidden(p) }
        // Outside home (temp dirs) the absolute system folders are off limits too.
        if !Self.isInside(p, of: h) {
            for f in Self.forbiddenAbsolute.map({ Self.canonical(URL(fileURLWithPath: $0)) }) where Self.isInside(p, of: f) {
                throw SafetyViolation.forbidden(p)
            }
        }
        if exceptions.contains(where: { Self.isInside(p, of: $0) }) { return }
        for f in activeForbiddenHomeRelative.map({ h + "/" + $0 }) {
            if Self.isInside(p, of: f) { throw SafetyViolation.forbidden(p) }
            if Self.isInside(f, of: p) { throw SafetyViolation.coversForbidden(p) }
        }
    }

    /// Validates a catalog root.
    public func checkRoot(_ root: URL) throws { try checkPath(root) }

    /// Full check of one item before deletion.
    /// - Parameters:
    ///   - allowRootItself: `itemMode == .root` rules delete the root directory as a whole.
    ///   - scannedFingerprint / currentFingerprint: newest modification date inside the item at scan time vs. now.
    public func check(item: URL, roots: [URL], allowRootItself: Bool = false,
                      scannedFingerprint: Date?, currentFingerprint: Date?) throws {
        let fm = FileManager.default
        let isLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        guard isLink || fm.fileExists(atPath: item.path) else { throw SafetyViolation.missing(item.path) }
        try checkPath(item)
        // A whole top-level folder of the home directory (~/Movies, ~/Developer, ~/Downloads…) is never an item.
        if (Self.canonical(item) as NSString).deletingLastPathComponent == Self.canonical(home) {
            var st = stat()
            if lstat(Self.canonical(item), &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { throw SafetyViolation.forbidden(Self.canonical(item)) }
        }
        // Containment is judged on the *resolved* path, so a symlink (the item or any parent) that
        // leads out of the root fails here.
        let resolved = Self.canonical(item)
        let resolvedRoots = roots.map(Self.canonical)
        guard resolvedRoots.contains(where: { Self.isInside(resolved, of: $0) }) else {
            let lexical = item.standardizedFileURL.path
            let nominallyInside = roots.contains { Self.isInside(lexical, of: $0.standardizedFileURL.path) }
            throw nominallyInside ? SafetyViolation.symlinkEscape(item.path) : SafetyViolation.outsideRoot(resolved)
        }
        if !allowRootItself, resolvedRoots.contains(resolved) { throw SafetyViolation.isRootItself(resolved) }
        if let s = scannedFingerprint, let c = currentFingerprint, c > s { throw SafetyViolation.modifiedAfterScan(item.path) }
    }

    public func checkCommand(_ command: [String]) throws {
        guard Self.allowedCommands.contains(command) else { throw SafetyViolation.commandNotAllowed(command) }
    }
}
