import Foundation

public enum AccessStatus: String, Sendable { case granted, denied, unknown }

/// Detects Full Disk Access by trying to open TCC-protected paths (read-only, nothing is read).
public struct FullDiskAccessProbe: Sendable {
    public var candidates: [String]

    public init(candidates: [String]) { self.candidates = candidates }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(candidates: [
            home.appendingPathComponent("Library/Safari/Bookmarks.plist").path,
            home.appendingPathComponent("Library/Safari").path,
            home.appendingPathComponent("Library/Messages").path,
            home.appendingPathComponent("Library/Mail").path,
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ])
    }

    /// System Settings pane where the user grants access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// granted: a protected path opened. denied: the OS refused (EPERM/EACCES). unknown: none of the paths exist.
    public func check() -> AccessStatus {
        var sawDenied = false
        for path in candidates {
            let fd = open(path, O_RDONLY)
            if fd >= 0 { close(fd); return .granted }
            switch errno {
            case EPERM, EACCES: sawDenied = true
            default: continue   // ENOENT etc.: this machine does not have the path
            }
        }
        return sawDenied ? .denied : .unknown
    }
}
