import SwiftUI
import DoCleanUI

/// Launch flags:
/// - `-gallery` — show the design-system gallery instead of the app.
/// - `-snapshot <path.png>` — render the gallery offscreen to PNG and quit.
/// - `-snapshot-screens <dir>` — real read-only scan, render every screen to `<dir>/*.png`, quit.
///   Cleaning there is always a dry run.
/// - `-render-icon <dir>` — render the app icon (1024 master + .iconset + AppIcon.icns) and quit.
/// - `-dry-run` — «тестовый режим»: nothing is deleted or moved, a badge is shown.
///   Real cleaning is the default since 1.0.0 (verified on a real Mac 2026-10-19).
@main
struct DoCleanApp: App {
    private let showGallery = CommandLine.arguments.contains("-gallery")
    /// Shared by the window and the menu-bar widget.
    @State private var model = AppModel(allowRealClean: !CommandLine.arguments.contains("-dry-run"))

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-snapshot"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            do {
                try GallerySnapshot.render(to: url)
                print("snapshot: \(url.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
        if let i = args.firstIndex(of: "-render-icon"), i + 1 < args.count {
            do {
                try AppIconRenderer.render(to: URL(fileURLWithPath: args[i + 1]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("icon failed: \(error)\n".utf8))
                exit(1)
            }
        }
        if let i = args.firstIndex(of: "-snapshot-screens"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            var finished = false
            var failure: (any Error)?
            Task { @MainActor in
                do { try await ScreenSnapshots.render(to: dir) } catch { failure = error }
                finished = true
            }
            // The app is not running yet: spin the main run loop until the async work is done.
            while !finished { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            if let failure {
                FileHandle.standardError.write(Data("snapshot failed: \(failure)\n".utf8))
                exit(1)
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("do clean", id: "main") {
            Group {
                if showGallery {
                    ScrollView([.horizontal, .vertical]) { GalleryView() }
                        .background(Color(hex: 0x0B0B0D))
                } else {
                    RootView(model: model)
                }
            }
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Needs `openWindow` from the scene environment.
private struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarView(model: model) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
