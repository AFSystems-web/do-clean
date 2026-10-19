import SwiftUI
import AppKit

/// The app icon in the house style: glass squircle, mesh glow, dot-matrix «do».
/// Drawn on the macOS grid: 1024 canvas, 824 squircle, 100 margin.
public struct AppIconView: View {
    public init() {}

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 186, style: .continuous)
        ZStack {
            Color.clear
            ZStack {
                Color(hex: 0x0E0F12)
                MeshBlur(.system, focus: .bottomTrailing, intensity: 1, animated: false)
                // Second hue from the opposite corner for depth.
                RadialGradient(colors: [Palette.xcode.primary.opacity(0.75), .clear],
                               center: UnitPoint(x: 0.1, y: 0.95), startRadius: 0, endRadius: 520)
                    .blendMode(.plusLighter)
                // Dark top for the glass look.
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55))
                // Sheen.
                LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02), .clear],
                               startPoint: .topLeading, endPoint: .center)
                DotMatrixText("do", style: DotMatrixStyle(dotSize: 37, spacing: 14, color: .white, offOpacity: 0.07,
                                                          glow: 0.85, shape: .circle))
                    .offset(y: 26)
            }
            .frame(width: 824, height: 824)
            .clipShape(shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05), .white.opacity(0.15)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 4))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Renders the icon master and the .icns.
public enum AppIconRenderer {
    public enum Failure: Error { case render, iconutil(Int32) }

    /// Writes `icon.png` (1024), `AppIcon.iconset/` and `AppIcon.icns` into `dir`.
    @MainActor
    public static func render(to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try png(scale: 1).write(to: dir.appendingPathComponent("icon.png"))

        let iconset = dir.appendingPathComponent("AppIcon.iconset")
        try? fm.removeItem(at: iconset)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            try png(scale: CGFloat(base) / 1024).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
            try png(scale: CGFloat(base * 2) / 1024).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.iconutil(p.terminationStatus) }
        print("icon: \(dir.path)")
    }

    @MainActor
    static func png(scale: CGFloat) throws -> Data {
        let renderer = ImageRenderer(content: AppIconView().environment(\.colorScheme, .dark))
        renderer.scale = scale
        renderer.isOpaque = false
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw Failure.render }
        return data
    }
}
