import SwiftUI
import AppKit
import DoCleanCore

/// Something that can tell whether Full Disk Access is granted. The core probe conforms;
/// tests and snapshots use a fixed value.
public protocol AccessChecking: Sendable {
    func check() -> AccessStatus
}

extension FullDiskAccessProbe: AccessChecking {}

public struct FixedAccess: AccessChecking {
    public var status: AccessStatus
    public init(_ status: AccessStatus) { self.status = status }
    public func check() -> AccessStatus { status }
}

/// Three onboarding pages: what it does, how tiers work, Full Disk Access.
struct OnboardingView: View {
    @Bindable var model: AppModel
    var probe: any AccessChecking = FullDiskAccessProbe()
    @State var page: Int = 0
    @State var access: AccessStatus = .unknown
    @State private var polling: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 10) {
                DotMatrixText("do", style: DotMatrixStyle(dotSize: 3.4, spacing: 1.3, color: Palette.system.accent, offOpacity: 0))
                Text("clean").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule().fill(.white.opacity(i == page ? 0.9 : 0.2)).frame(width: i == page ? 22 : 8, height: 8)
                    }
                }
                .animation(Theme.Motion.spring, value: page)
            }

            ZStack {
                switch page {
                case 0: welcome.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
                case 1: tiers.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
                default: fullDiskAccess.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if page > 0 {
                    PillButton("Назад", systemImage: "chevron.left") { withAnimation(Theme.Motion.spring) { page -= 1 } }
                }
                Spacer()
                if page < 2 {
                    PrimaryScanButton("Дальше", palette: .system, animated: model.animated) {
                        withAnimation(Theme.Motion.spring) { page += 1 }
                    }
                    .frame(width: 260)
                } else {
                    PrimaryScanButton(access == .granted ? "Начать" : "Продолжить",
                                      subtitle: access == .granted ? "Доступ есть" : "Без полного доступа",
                                      palette: access == .granted ? .system : .trash, animated: model.animated) {
                        model.finishOnboarding()
                    }
                    .frame(width: 300)
                }
            }
        }
        .padding(Theme.Metrics.screenPadding)
        .background(Theme.Colors.background.ignoresSafeArea())
        .onAppear { access = probe.check() }
        .onChange(of: page) { _, p in if p == 2 { startPolling() } else { polling?.cancel() } }
        .onDisappear { polling?.cancel() }
    }

    // MARK: Pages

    private var welcome: some View {
        HStack(spacing: Theme.Metrics.gridSpacing) {
            GlassCard("Освобождаем место", subtitle: "Только то, что пересоздастся само", systemImage: "sparkles",
                      palette: .system, focus: .bottomLeading, animated: model.animated) {
                VStack(alignment: .leading, spacing: 14) {
                    DotMatrixNumber(108, unit: "ГБ", style: DotMatrixStyle(dotSize: 15, spacing: 5))
                    Text("Кэши программ, Xcode, Adobe, AI-модели, старые загрузки. Сначала скан — ничего не удаляется, пока ты не нажмёшь «Очистить».")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: 560, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: Theme.Metrics.gridSpacing) {
                OnboardingFact(icon: "eye", title: "Сначала показываем", text: "Каждая находка — с размером и объяснением, почему это безопасно.", palette: .xcode, animated: model.animated)
                OnboardingFact(icon: "arrow.uturn.backward", title: "Личное — в Корзину", text: "Твои файлы не удаляются насовсем: их можно вернуть.", palette: .ai, animated: model.animated)
                OnboardingFact(icon: "lock.shield", title: "Систему не трогаем", text: "Фото, почта, пароли, iCloud и системные папки закрыты навсегда.", palette: .adobe, animated: model.animated)
            }
            .frame(width: 400)
        }
    }

    private var tiers: some View {
        HStack(spacing: Theme.Metrics.gridSpacing) {
            TierCard(kind: .safe, title: "Безопасно", text: "Кэши и временные файлы. Программы создадут их заново. Отмечено заранее.",
                     examples: "DerivedData · кэш After Effects · логи", palette: .system, animated: model.animated)
            TierCard(kind: .review, title: "Проверь", text: "Можно скачать или собрать снова, но это время и трафик. Отмечаешь сам.",
                     examples: "AI-модели · симуляторы · архивы Xcode", palette: .downloads, animated: model.animated)
            TierCard(kind: .personal, title: "Личное", text: "Твои файлы. Только по одному, с явным списком, и только в Корзину.",
                     examples: "Загрузки · большие файлы · дубликаты", palette: .adobe, animated: model.animated)
        }
    }

    private var fullDiskAccess: some View {
        GlassCard("Полный доступ к диску", subtitle: "Чтобы видеть кэши Safari, Почты и Корзину",
                  systemImage: "externaldrive.badge.checkmark", palette: access == .granted ? .system : .xcode,
                  focus: .bottom, animated: model.animated) {
            HStack(alignment: .center, spacing: 40) {
                VStack(alignment: .leading, spacing: 14) {
                    step(1, "Нажми «Открыть Настройки»")
                    step(2, "Включи переключатель у «do clean»")
                    step(3, "Вернись сюда — приложение само заметит")
                    HStack(spacing: 10) {
                        PillButton("Открыть Настройки", systemImage: "gearshape", selected: true) {
                            NSWorkspace.shared.open(FullDiskAccessProbe.settingsURL)
                            startPolling()
                        }
                        accessBadge
                    }
                    .padding(.top, 6)
                    Text("Без доступа приложение тоже работает: просто часть мест будет пропущена.")
                        .font(Theme.Fonts.footer).foregroundStyle(Theme.Colors.textTertiary)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.08), lineWidth: 14)
                    Circle().trim(from: 0, to: access == .granted ? 1 : 0.18)
                        .stroke(access == .granted ? Theme.Colors.safe : Palette.xcode.secondary,
                                style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(7)
                        .animation(Theme.Motion.spring, value: access)
                    Image(systemName: access == .granted ? "checkmark" : "lock.fill")
                        .font(.system(size: 54, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 200, height: 200)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var accessBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(access == .granted ? Theme.Colors.safe : Theme.Colors.review).frame(width: 7, height: 7)
            Text(access == .granted ? "Доступ есть" : (polling != nil ? "Жду доступ…" : "Доступа пока нет"))
                .font(Theme.Fonts.badge)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10).frame(height: 26)
        .background(Capsule().fill(.black.opacity(0.35)))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            DotMatrixText("\(n)", style: .medium)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.08)))
            Text(text).font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
        }
    }

    /// Re-checks the probe every second until access appears.
    private func startPolling() {
        guard polling == nil, access != .granted else { return }
        let probe = probe
        polling = Task { @MainActor in
            while !Task.isCancelled {
                let status = probe.check()
                if status != access { withAnimation(Theme.Motion.spring) { access = status } }
                if status == .granted { break }
                try? await Task.sleep(for: .seconds(1))
            }
            polling = nil
        }
    }
}

private struct OnboardingFact: View {
    let icon: String
    let title: String
    let text: String
    let palette: Palette
    let animated: Bool

    var body: some View {
        GlassCard(title, systemImage: icon, palette: palette, focus: .trailing, glow: 0.55, animated: animated) {
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TierCard: View {
    let kind: TierBadge.Kind
    let title: String
    let text: String
    let examples: String
    let palette: Palette
    let animated: Bool

    private var numeral: String {
        switch kind {
        case .safe: "01"
        case .review: "02"
        case .personal: "03"
        }
    }

    var body: some View {
        GlassCard(title, palette: palette, focus: .bottom, animated: animated) {
            VStack(alignment: .leading, spacing: 14) {
                Text(text).font(.system(size: 15)).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                DotMatrixText(numeral, style: DotMatrixStyle(dotSize: 12, spacing: 4.5))
                    .frame(maxWidth: .infinity)
                Spacer()
                HStack(spacing: 8) {
                    TierBadge(kind, compact: true)
                    Text(examples).font(Theme.Fonts.footer).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(Capsule().fill(.black.opacity(0.45)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 10)
        }
    }
}
