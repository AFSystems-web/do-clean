import SwiftUI
import AppKit
import DoCleanCore

/// Menu-bar widget: free space in dot digits and «Быстрая чистка».
public struct MenuBarView: View {
    @Bindable var model: AppModel
    let openMainWindow: () -> Void

    public init(model: AppModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
    }

    public var body: some View {
        let disk = model.disk
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                DotMatrixText("do", style: DotMatrixStyle(dotSize: 2.4, spacing: 1, color: Palette.system.accent, offOpacity: 0))
                Text("clean").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                if model.isDryRun { DryRunBadge() }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Свободно на Macintosh HD").font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textSecondary)
                let d = ByteDisplay(disk.free)
                DotMatrixNumber(d.value, decimals: d.decimals, unit: d.unit, style: .large)
                TickScale(value: disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0, tickCount: 41,
                          color: Palette.system.accent, leadingLabel: "0", trailingLabel: "\(Int(Double(disk.total) / 1e9))", height: 16)
            }
            if let r = model.lastResult {
                HStack {
                    TierBadge(.safe, compact: true)
                    Text("Безопасно можно освободить \(shortBytes(r.bytes(tier: .green)))")
                        .font(Theme.Fonts.footer).foregroundStyle(.white.opacity(0.8))
                }
            }
            PrimaryScanButton("Быстрая чистка", subtitle: "Только зелёное, с подтверждением",
                              palette: .system, animated: model.animated) {
                model.quickClean()
                openMainWindow()
            }
            HStack {
                Button("Открыть do clean") { openMainWindow() }
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(Theme.Fonts.footer).foregroundStyle(.white.opacity(0.7))
        }
        .padding(18)
        .frame(width: 340)
        .background {
            ZStack {
                Theme.Colors.background
                MeshBlur(.system, focus: .bottom, intensity: 0.45, animated: model.animated)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.refreshDisk() }
    }
}

/// Label in the menu bar: icon + free space.
public struct MenuBarLabel: View {
    @Bindable var model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
            Text(shortBytes(model.disk.free))
        }
    }
}
