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
            let id = try #require(glyph(scalar, in: font), "U+\(String(scalar.value, radix: 16, uppercase: true))")
            let path = try #require(CTFontCreatePathForGlyph(font, id, nil))
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
        // Ordinary symbols the icon font also has (♥ ⚡ ❯) are left to the system, and a private-use
        // character it lacks to whatever font has it.
        for other: Unicode.Scalar in ["8", "|", "\u{2502}", "\u{1FBEF}", "\u{1FBFA}", "\u{2665}", "\u{26A1}", "\u{276F}", "\u{E0FF}", "\u{F8FF}"] {
            #expect(CodecGlyphs.shared.placementPolicy(for: other) == nil, "U+\(String(other.value, radix: 16, uppercase: true))")
        }
    }

    /// Nerd Fonts' icons (a folder, Swift's bird, git's branch, a power symbol) come from the symbol
    /// font the glyph font cascades to, placed as icons; Powerline's separators fill their cell.
    @Test func fallsBackToNerdFontIcons() throws {
        let font = try #require(CodecGlyphs.shared.fallbackFont(forPointSize: 13))
        for scalar: Unicode.Scalar in ["\u{F07B}", "\u{E755}", "\u{F418}", "\u{F0001}", "\u{23FB}"] {
            let policy = try #require(CodecGlyphs.shared.placementPolicy(for: scalar), "U+\(String(scalar.value, radix: 16, uppercase: true))")
            #expect(policy.placement == .icon)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(scalar),
                                                                           attributes: [.init(kCTFontAttributeName as String): font]))
            let run = try #require((CTLineGetGlyphRuns(line) as? [CTRun])?.first)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            #expect(CTFontCopyPostScriptName(runFont) as String == "SymbolsNF")
        }
        #expect(CodecGlyphs.shared.placementPolicy(for: "\u{E0B4}")?.placement == .stretch)
        #expect(CodecGlyphs.shared.placementPolicy(for: "\u{E0C0}")?.placement == .stretch)
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
