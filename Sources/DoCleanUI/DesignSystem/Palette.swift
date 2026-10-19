import SwiftUI

/// Category color pairs used by `MeshBlur`, rings, scales and accents (SPEC §4).
public enum Palette: String, CaseIterable, Sendable, Identifiable {
    case system      // green / teal
    case adobe       // red / magenta
    case xcode       // blue / cyan
    case ai          // violet / purple
    case downloads   // lime / olive
    case personal    // orange / amber
    case trash       // grey / steel

    public var id: String { rawValue }

    /// Main vivid color of the pair.
    public var primary: Color { Color(hex: hexes.primary) }
    /// Second color of the pair.
    public var secondary: Color { Color(hex: hexes.secondary) }
    /// Deep, dark tint of the pair: fills the "shadow" side of the mesh.
    public var deep: Color { Color(hex: hexes.deep) }
    /// Accent for dot digits, ticks and markers on top of this palette.
    public var accent: Color { Color(hex: hexes.accent) }

    public var colors: [Color] { [primary, secondary] }

    /// Raw hex values, exposed for tests and for the icon generator.
    public var hexes: (primary: UInt32, secondary: UInt32, deep: UInt32, accent: UInt32) {
        switch self {
        case .system:    (0x10D98A, 0x0FB5C9, 0x05372F, 0xB9FFE0)
        case .adobe:     (0xFF2D55, 0xE0249A, 0x3D0A1F, 0xFFC2D4)
        case .xcode:     (0x2F6BFF, 0x19C8FF, 0x0A1C4A, 0xC4E9FF)
        case .ai:        (0x8B5CF6, 0xC026D3, 0x22104A, 0xE4D4FF)
        case .downloads: (0xB6F23A, 0x6B8E23, 0x1F2A08, 0xEFFFC2)
        case .personal:  (0xFF8A1F, 0xFFC23D, 0x3F1E05, 0xFFE3BF)
        case .trash:     (0x8E99A8, 0x4B5A6E, 0x161B22, 0xE2E8F0)
        }
    }

    /// Human name, used by the gallery and accessibility labels.
    public var title: String {
        switch self {
        case .system: "Система"
        case .adobe: "Adobe"
        case .xcode: "Xcode"
        case .ai: "AI"
        case .downloads: "Загрузки"
        case .personal: "Личное"
        case .trash: "Корзина"
        }
    }
}
