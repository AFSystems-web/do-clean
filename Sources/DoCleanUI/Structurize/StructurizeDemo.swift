import Foundation
import DoCleanCore

/// A throwaway home folder with believable files, for snapshots and tests.
/// Lives in the temp directory; nothing here touches the user's files.
enum StructurizeDemo {
    struct Home {
        let home: URL
        let environment: DoCleanEnvironment
    }

    private struct NoCommands: CommandRunner {
        func locate(_ name: String) -> String? { nil }
        func run(_ executable: String, _ args: [String]) -> CommandOutput { CommandOutput(status: 1, stdout: "") }
    }

    static func make() throws -> Home {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("doclean-structurize-demo-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop")
        let docs = home.appendingPathComponent("Documents")
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)

        // (relative path, size KB, days ago)
        let files: [(String, Int, Int)] = [
            ("Desktop/Nike_clip_v1.mp4", 4200, 9), ("Desktop/Nike_clip_v2_final.mp4", 4800, 6),
            ("Desktop/Nike_clip_music.wav", 1800, 9), ("Desktop/Nike_clip_storyboard.pdf", 600, 12),
            ("Desktop/Nike_clip_render_0012.png", 900, 7), ("Desktop/Nike AE/Nike.aep", 1200, 6),
            ("Desktop/Nike AE/footage/A001.mov", 2600, 10),
            ("Desktop/Vlog_paris_cut.mp4", 3600, 20), ("Desktop/Vlog_paris_voice.m4a", 700, 21),
            ("Desktop/Vlog Premiere/Vlog.prproj", 800, 18),
            ("Desktop/IMG_2041.HEIC", 1400, 40), ("Desktop/IMG_2042.HEIC", 1500, 40),
            ("Desktop/Screenshot 2026-10-12.png", 380, 7), ("Desktop/invoice-october.pdf", 120, 5),
            ("Desktop/Figma-installer.dmg", 3100, 30), ("Desktop/brand-assets.zip", 2200, 15),
            ("Desktop/notes.md", 8, 2), ("Desktop/logo.psd", 2400, 25), ("Desktop/script.py", 6, 3),
            ("Documents/contract-2025.pdf", 300, 400), ("Documents/ideas.txt", 4, 3), ("Documents/budget.xlsx", 90, 50),
        ]
        for (rel, kb, days) in files {
            let url = home.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: kb * 1024).write(to: url)
            let date = Date().addingTimeInterval(-Double(days) * 86_400)
            try fm.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
        }
        for folder in ["Desktop/Nike AE/footage", "Desktop/Nike AE", "Desktop/Vlog Premiere"] {
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-6 * 86_400)],
                                 ofItemAtPath: home.appendingPathComponent(folder).path)
        }
        let env = DoCleanEnvironment(home: home, tmpDir: home.appendingPathComponent("tmp"),
                                     probe: FixedAppStateProbe(), runner: NoCommands())
        return Home(home: home, environment: env)
    }
}
