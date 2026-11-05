import CoreText
import Foundation
import SwiftTerm

/// Nerd Fonts' symbols: the file, folder, language and tool icons that eza, lsd, starship and editors'
/// file trees print as private-use characters. Codec's glyph font falls back to this one, so they show
/// in any font; a font patched with them keeps its own.
///
/// The font ships in the app's Resources/Fonts (MIT; see SymbolsNerdFont-LICENSE.txt beside it).
enum SymbolFont {
    static let fileName = "SymbolsNerdFont-Regular.ttf"

    /// The font, or nil when it can't be found or read: icons then show as the terminal font draws them.
    /// Descriptors are immutable, so safe to share between threads.
    nonisolated(unsafe) static let descriptor: CTFontDescriptor? = {
        guard let url = location, let data = try? Data(contentsOf: url) else { return nil }
        return CTFontManagerCreateFontDescriptorFromData(data as CFData)
    }()

    /// In the app bundle, or, for development builds and tests, in the repository.
    private static var location: URL? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts/\(fileName)"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/Fonts/\(fileName)"),
        ]
        return candidates.compactMap { $0 }.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// The characters the font has where icons live: the private-use areas, and the power symbols
    /// (⏻ ⏼ ⏽ ⏾ ⭘). It has a few ordinary symbols too (♥ ⚡ ❮ ❯), left to the system's fallback.
    static let coverage: CharacterSet = {
        guard let descriptor else { return CharacterSet() }
        let all = CTFontCopyCharacterSet(CTFontCreateWithFontDescriptor(descriptor, 12, nil)) as CharacterSet
        var icons = CharacterSet()
        for range in iconRanges {
            icons.insert(charactersIn: Unicode.Scalar(range.lowerBound)!...Unicode.Scalar(range.upperBound)!)
        }
        return all.intersection(icons)
    }()

    private static let iconRanges: [ClosedRange<UInt32>] = [0x23FB...0x23FE, 0x2B58...0x2B58, 0xE000...0xF8FF, 0xF0000...0xFFFFD]

    /// Powerline's separators and their variants (flames, pixels, slants) fill the cell, to join the
    /// colored segments on either side. SwiftTerm draws the common ones itself.
    private static let separators: ClosedRange<UInt32> = 0xE0B0...0xE0D7

    private static let icon = TerminalGlyphPlacementPolicy(placement: .icon)
    private static let separator = TerminalGlyphPlacementPolicy(placement: .stretch)

    /// How `scalar` is placed, or nil when the font doesn't have it. Asked for every cell drawn, so the
    /// ranges are checked first.
    static func policy(for scalar: Unicode.Scalar) -> TerminalGlyphPlacementPolicy? {
        let value = scalar.value
        guard value >= 0x23FB, iconRanges.contains(where: { $0.contains(value) }), coverage.contains(scalar) else { return nil }
        return separators.contains(value) ? separator : icon
    }
}
