import XCTest
@testable import DoCleanUI

final class DotMatrixFontTests: XCTestCase {
    func testRequiredGlyphsAreCovered() {
        for ch in DotMatrixFont.requiredCharacters {
            XCTAssertNotNil(DotMatrixFont.glyph(for: ch), "missing glyph for «\(ch)»")
        }
        for unit in ["ГБ", "МБ", "GB", "MB", "КБ", "ТБ", "KB", "TB"] {
            XCTAssertTrue(DotMatrixFont.covers(unit), unit)
        }
    }

    func testGlyphsAreSevenRowsAndRectangular() {
        for ch in DotMatrixFont.supportedCharacters {
            let g = DotMatrixFont.glyph(for: ch)!
            XCTAssertEqual(g.bits.count, DotMatrixFont.rows, "«\(ch)»")
            XCTAssertTrue(g.bits.allSatisfy { $0.count == g.width }, "«\(ch)»")
        }
    }

    func testDigitsAndLettersAreFullWidth() {
        for ch in Array("0123456789ГБМGBM") {
            XCTAssertEqual(DotMatrixFont.glyph(for: ch)?.width, DotMatrixFont.fullWidth, "«\(ch)»")
        }
    }

    func testDigitsAreDistinctAndNonEmpty() {
        let digits = Array("0123456789").compactMap(DotMatrixFont.glyph(for:))
        XCTAssertEqual(digits.count, 10)
        XCTAssertEqual(Set(digits.map { $0.bits.description }).count, 10)
        XCTAssertTrue(digits.allSatisfy { $0.bits.joined().contains(true) })
    }

    func testWidthDoesNotDependOnDigitValues() {
        // Monospaced: same structure → same width, so numbers do not jitter.
        XCTAssertEqual(DotMatrixLayout("11,1").columns, DotMatrixLayout("88,8").columns)
        XCTAssertEqual(DotMatrixLayout("09:50").columns, DotMatrixLayout("23:17").columns)
    }

    func testUnknownCharactersAreNotCovered() {
        XCTAssertFalse(DotMatrixFont.covers("Ж"))
    }

    func testFormat() {
        XCTAssertEqual(DotMatrixNumber.format(46, decimals: 0), "46")
        XCTAssertEqual(DotMatrixNumber.format(3.25, decimals: 1), "3,3")
        XCTAssertEqual(DotMatrixNumber.format(0.05, decimals: 2), "0,05")
        XCTAssertEqual(DotMatrixNumber.format(12_345, decimals: 0), "12 345")
        XCTAssertEqual(DotMatrixNumber.format(-4, decimals: 0), "-4")
        XCTAssertEqual(DotMatrixNumber.format(45, decimals: 0, suffix: "%"), "45%")
        XCTAssertTrue(DotMatrixFont.covers(DotMatrixNumber.format(98_765.4, decimals: 1)))
    }
}

final class PaletteTests: XCTestCase {
    func testPaletteKeys() {
        XCTAssertEqual(Set(Palette.allCases.map(\.rawValue)),
                       ["system", "adobe", "xcode", "ai", "downloads", "personal", "trash"])
    }

    func testPalettesHaveDistinctPrimaryColors() {
        let primaries = Palette.allCases.map(\.hexes.primary)
        XCTAssertEqual(Set(primaries).count, primaries.count)
    }

    func testDeepIsDarkerThanPrimary() {
        func luma(_ hex: UInt32) -> Double {
            0.2126 * Double((hex >> 16) & 0xFF) + 0.7152 * Double((hex >> 8) & 0xFF) + 0.0722 * Double(hex & 0xFF)
        }
        for p in Palette.allCases {
            XCTAssertLessThan(luma(p.hexes.deep), luma(p.hexes.primary), p.rawValue)
        }
    }

    func testTierBadgeKinds() {
        XCTAssertEqual(TierBadge.Kind.allCases.map(\.title), ["Безопасно", "Проверь", "Личное"])
    }

    @MainActor
    func testGallerySnapshotRenders() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("doclean-gallery-test.png")
        try GallerySnapshot.render(to: url, scale: 1)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 10_000)
    }
}
