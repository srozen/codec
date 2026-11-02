import Testing
import CoreText
import Foundation
import CodecCore
@testable import CodecUI

@Suite("Codec glyphs")
struct CodecGlyphsTests {
    private let scalars = PromptConfiguration.lcdDigits.map { $0.unicodeScalars.first! }
        + [PromptConfiguration.panelCorners.open, PromptConfiguration.panelCorners.close].map { $0.unicodeScalars.first! }

    private func glyph(_ scalar: Unicode.Scalar, in font: CTFont) -> CGGlyph? {
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count), glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }

    @Test func coreTextLoadsTheFontWithEveryGlyph() throws {
        let font = try #require(CodecGlyphs.shared.fallbackFont(forPointSize: 13))
        #expect(CTFontCopyPostScriptName(font) as String == "CodecGlyphs-Regular")
        for scalar in scalars {
            let glyph = try #require(glyph(scalar, in: font), "U+\(String(scalar.value, radix: 16, uppercase: true))")
            let path = try #require(CTFontCreatePathForGlyph(font, glyph, nil))
            #expect(!path.boundingBoxOfPath.isEmpty)
        }
    }

    @Test func returnsTheSameFontForASize() {
        #expect(CodecGlyphs.shared.fallbackFont(forPointSize: 13) === CodecGlyphs.shared.fallbackFont(forPointSize: 13))
        #expect(CodecGlyphs.shared.fallbackFont(forPointSize: 13) !== CodecGlyphs.shared.fallbackFont(forPointSize: 14))
    }

    /// Claiming more would replace glyphs the terminal's font draws for other programs.
    @Test func claimsOnlyItsOwnCharacters() {
        for scalar in scalars { #expect(CodecGlyphs.shared.placementPolicy(for: scalar) != nil) }
        for other: Unicode.Scalar in ["8", "|", "\u{2502}", "\u{1FBEF}", "\u{1FBFA}", "\u{E0B4}"] {
            #expect(CodecGlyphs.shared.placementPolicy(for: other) == nil)
        }
    }

    /// Digits fit as one group: a 1 sits where an 8's right segments are, not stretched across the cell.
    @Test func digitsShareOneBox() throws {
        let font = try #require(CodecGlyphs.shared.fallbackFont(forPointSize: 1000))
        func bounds(_ digit: Int) throws -> CGRect {
            let scalar = PromptConfiguration.lcdDigits[digit].unicodeScalars.first!
            let id = try #require(glyph(scalar, in: font))
            return try #require(CTFontCreatePathForGlyph(font, id, nil)).boundingBoxOfPath
        }
        let eight = try bounds(8), one = try bounds(1)
        let box = GlyphFont.digitBox
        #expect(eight == CGRect(x: box.x, y: 0, width: box.width, height: box.height))
        #expect(one.maxX == eight.maxX && one.minX > eight.midX)

        let relative = try #require(CodecGlyphs.shared.placementPolicy(for: "\u{1FBF1}")?.relativeBounds)
        #expect(abs(relative.minX * eight.width + eight.minX - one.minX) < 0.5)
        #expect(abs(relative.width * eight.width - one.width) < 0.5)
        #expect(CodecGlyphs.shared.placementPolicy(for: "\u{1FBF8}")?.relativeBounds == CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
