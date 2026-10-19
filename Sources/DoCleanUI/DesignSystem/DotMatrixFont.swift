import Foundation

/// A 5×7 dot-matrix bitmap font, drawn by `DotMatrixText` on a Canvas.
/// Own glyph table: no external fonts, no licences (SPEC §4).
public enum DotMatrixFont {
    public static let rows = 7
    /// Width of digits and letters in columns.
    public static let fullWidth = 5

    public struct Glyph: Sendable, Equatable {
        /// Number of columns this glyph occupies.
        public let width: Int
        /// `rows` rows, each `width` bools, true = lit.
        public let bits: [[Bool]]

        init(_ pattern: [String]) {
            precondition(pattern.count == DotMatrixFont.rows, "glyph needs \(DotMatrixFont.rows) rows")
            let w = pattern.map(\.count).max() ?? 0
            width = w
            bits = pattern.map { row in
                let chars = Array(row)
                return (0..<w).map { $0 < chars.count && chars[$0] == "#" }
            }
        }

        public func isLit(row: Int, column: Int) -> Bool {
            guard row >= 0, row < bits.count, column >= 0, column < width else { return false }
            return bits[row][column]
        }
    }

    /// Glyph for a character, or nil when the font does not cover it.
    public static func glyph(for character: Character) -> Glyph? {
        table[character]
    }

    /// Every character the font can draw.
    public static var supportedCharacters: Set<Character> { Set(table.keys) }

    /// True when every character of `text` has a glyph.
    public static func covers(_ text: String) -> Bool {
        text.allSatisfy { table[$0] != nil }
    }

    /// Characters required by the spec: digits, punctuation and storage units.
    public static let requiredCharacters: [Character] =
        Array("0123456789.,%°:-/ ") + Array("ГБМКТ") + Array("GBMKT")

    // MARK: Table

    private static let table: [Character: Glyph] = {
        var t: [Character: Glyph] = [:]
        t["0"] = Glyph([".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."])
        t["1"] = Glyph(["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."])
        t["2"] = Glyph([".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"])
        t["3"] = Glyph([".###.", "#...#", "....#", "..##.", "....#", "#...#", ".###."])
        t["4"] = Glyph(["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."])
        t["5"] = Glyph(["#####", "#....", "####.", "....#", "....#", "#...#", ".###."])
        t["6"] = Glyph(["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."])
        t["7"] = Glyph(["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."])
        t["8"] = Glyph([".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."])
        t["9"] = Glyph([".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."])

        t["."] = Glyph([".", ".", ".", ".", ".", ".", "#"])
        t[","] = Glyph(["..", "..", "..", "..", "..", ".#", "#."])
        t[":"] = Glyph([".", ".", "#", ".", "#", ".", "."])
        t["%"] = Glyph(["##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##"])
        t["°"] = Glyph([".#.", "#.#", ".#.", "...", "...", "...", "..."])
        t["-"] = Glyph(["....", "....", "....", "####", "....", "....", "...."])
        t["−"] = t["-"]
        t["+"] = Glyph([".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."])
        t["/"] = Glyph(["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."])
        // Lowercase for the «do» wordmark.
        t["d"] = Glyph(["....#", "....#", ".####", "#...#", "#...#", "#...#", ".####"])
        t["o"] = Glyph([".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###."])
        t[" "] = Glyph(["..", "..", "..", "..", "..", "..", ".."])

        // Storage units, Latin and Cyrillic.
        t["G"] = Glyph([".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."])
        t["B"] = Glyph(["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."])
        t["M"] = Glyph(["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"])
        t["K"] = Glyph(["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"])
        t["T"] = Glyph(["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."])
        t["Г"] = Glyph(["#####", "#....", "#....", "#....", "#....", "#....", "#...."])
        t["Б"] = Glyph(["#####", "#....", "#....", "####.", "#...#", "#...#", "####."])
        t["М"] = t["M"]
        t["К"] = t["K"]
        t["Т"] = t["T"]
        return t
    }()
}
