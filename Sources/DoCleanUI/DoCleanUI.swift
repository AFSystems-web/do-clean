import SwiftUI
import DoCleanCore

/// Root view of the app: top bar with sections and the home flow.
public struct RootView: View {
    @State private var model: AppModel

    public init(allowRealClean: Bool = false) {
        _model = State(initialValue: AppModel(allowRealClean: allowRealClean))
    }

    public init(model: AppModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        MainView(model: model)
            .frame(minWidth: 1100, minHeight: 760)
    }
}

/// Shell: top bar + current section.
struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, 30)
                .padding(.bottom, 18)
            Group {
                switch model.section {
                case .home: HomeFlowView(model: model)
                case .tools: ToolsView(model: model)
                case .structurize: StructurizeView(model: model, s: model.structurize)
                case .history: HistoryView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Colors.background.ignoresSafeArea())
        .overlay {
            if model.showOnboarding {
                OnboardingView(model: model).transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.confirming, onDismiss: { model.confirmDismissed() }) {
            ConfirmCleanSheet(model: model)
        }
    }
}

struct TopBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Spacing.l) {
            HStack(spacing: 10) {
                DotMatrixText("do", style: DotMatrixStyle(dotSize: 3, spacing: 1.2, color: Palette.system.accent, offOpacity: 0))
                Text("clean").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
            }
            if model.isDryRun {
                DryRunBadge()
            }
            Spacer()
            PillPicker(AppSection.allCases.map { ($0, $0.title) }, selection: $model.section)
            Spacer()
            ClockView(animated: model.animated)
        }
    }
}

/// «тестовый режим»: shown while real deletion is disabled.
struct DryRunBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "testtube.2").font(.system(size: 10, weight: .bold))
            Text("тестовый режим").font(Theme.Fonts.badge)
        }
        .foregroundStyle(Theme.Colors.review)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Theme.Colors.review.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Theme.Colors.review.opacity(0.4), lineWidth: 0.5))
        .help("Файлы не удаляются: очистка только показывает, что было бы освобождено")
    }
}

/// Dot-matrix wall clock, like «09:50» on the reference.
struct ClockView: View {
    let animated: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            DotMatrixText(Self.format(animated ? context.date : Date()), style: .medium)
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(Capsule().fill(.white.opacity(0.05)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        }
    }

    static func format(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
