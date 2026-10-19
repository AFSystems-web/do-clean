import SwiftUI

/// Design tokens of do clean: colors, typography, spacing, motion.
/// There is no light theme — the dark look *is* the brand (SPEC §4).
public enum Theme {

    // MARK: Colors

    public enum Colors {
        /// App background `#0B0B0D`.
        public static let background = Color(hex: 0x0B0B0D)
        /// Base of every card under the glass and the mesh blur.
        public static let cardBase = Color(hex: 0x141418)
        /// Slightly lighter surface for inner wells (ring track, pill background).
        public static let well = Color.white.opacity(0.06)
        public static let textPrimary = Color.white
        public static let textSecondary = Color.white.opacity(0.55)
        public static let textTertiary = Color.white.opacity(0.32)
        /// Hairline stroke on glass edges.
        public static let hairline = Color.white.opacity(0.10)

        public static let safe = Color(hex: 0x34D399)
        public static let review = Color(hex: 0xFACC15)
        public static let personal = Color(hex: 0xF43F5E)
    }

    // MARK: Typography

    public enum Fonts {
        /// SF Pro Display Semibold — the system font switches to Display at these sizes.
        public static func title(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .semibold) }
        public static let cardTitle = Font.system(size: 17, weight: .semibold)
        public static let cardSubtitle = Font.system(size: 13, weight: .regular)
        public static let screenTitle = Font.system(size: 30, weight: .semibold)
        public static let footer = Font.system(size: 12, weight: .medium)
        public static let button = Font.system(size: 14, weight: .semibold)
        public static let badge = Font.system(size: 11, weight: .semibold)
        public static let unitLabel = Font.system(size: 15, weight: .semibold)
    }

    // MARK: Geometry

    public enum Metrics {
        public static let cardRadius: CGFloat = 28
        public static let cardPadding: CGFloat = 20
        public static let gridSpacing: CGFloat = 14
        public static let screenPadding: CGFloat = 32
    }

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    // MARK: Motion

    public enum Motion {
        /// Default UI spring (cards, toggles, markers).
        public static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
        /// Snappy spring for hover/press feedback.
        public static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.75)
        /// Count-up of dot-matrix numbers.
        public static let count = Animation.spring(response: 1.1, dampingFraction: 0.92)
        /// Period of the mesh "breathing", seconds.
        public static let breathPeriod: Double = 9
    }
}

public extension Color {
    /// `Color(hex: 0x0B0B0D)`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
