import AppKit
import SwiftTerm
import CodecCore

/// A Codec colour scheme.
struct CodecTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let isDark: Bool
    let background: NSColor
    let foreground: NSColor
    /// Used for the caret, the active-tab highlight and the status readouts.
    let accent: NSColor
    /// Used for errors, failed commands and the bell indicator.
    let alert: NSColor
    let selection: NSColor
    /// The 16 ANSI colours: 8 normal followed by 8 bright.
    let ansi: [NSColor]

    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }
    /// Hairlines between panes and around the bars.
    var divider: NSColor { foreground.withAlphaComponent(isDark ? 0.1 : 0.14) }
    var terminalPalette: [SwiftTerm.Color] { ansi.map(\.terminalColor) }

    /// The pill behind a prompt chip of `color`: that color washed over the background, as `#rrggbb`.
    func promptChipFill(_ color: PromptConfiguration.Color) -> String {
        (background.blended(withFraction: isDark ? 0.18 : 0.16, of: ansi[color.ansiIndex]) ?? background).hexString
    }

    var promptChipFills: [PromptConfiguration.Color: String] {
        Dictionary(uniqueKeysWithValues: PromptConfiguration.Color.allCases.map { ($0, promptChipFill($0)) })
    }

    /// A panel tag in `color`: that color halfway into the background, so the value after it stands out.
    func promptTagColor(_ color: PromptConfiguration.Color) -> String {
        (background.blended(withFraction: 0.5, of: ansi[color.ansiIndex]) ?? background).hexString
    }

    var promptTagColors: [PromptConfiguration.Color: String] {
        Dictionary(uniqueKeysWithValues: PromptConfiguration.Color.allCases.map { ($0, promptTagColor($0)) })
    }

    /// The panel prompt's corners and bars: the accent, dimmed.
    var promptFrameColor: String {
        (background.blended(withFraction: 0.5, of: accent) ?? accent).hexString
    }

    static let all: [CodecTheme] = [.codec, .arctic, .amber, .daylight]

    static func named(_ id: String) -> CodecTheme {
        all.first { $0.id == id } ?? .codec
    }
}

extension CodecTheme {
    static let codec = CodecTheme(
        id: "codec",
        name: "Codec",
        summary: "Near-black with a phosphor-green accent.",
        isDark: true,
        background: NSColor(hex: 0x0A0F0C),
        foreground: NSColor(hex: 0xE3EAE6),
        accent: NSColor(hex: 0x52FFA8),
        alert: NSColor(hex: 0xFF3B4E),
        selection: NSColor(hex: 0x1D5C3E),
        ansi: [
            0x161C19, 0xFF5C6C, 0x4DE89A, 0xE6D07A, 0x5CB8FF, 0xC792EA, 0x4DD8D8, 0xC5CCC8,
            0x58625D, 0xFF8A95, 0x8CFFC2, 0xFFE89E, 0x8FD0FF, 0xDDB6F2, 0x8CF0EA, 0xF4F7F5,
        ].map(NSColor.init(hex:))
    )

    static let arctic = CodecTheme(
        id: "arctic",
        name: "Arctic",
        summary: "Cool blue-grey with an ice-blue accent.",
        isDark: true,
        background: NSColor(hex: 0x070B12),
        foreground: NSColor(hex: 0xC9D7E8),
        accent: NSColor(hex: 0x7FD4FF),
        alert: NSColor(hex: 0xFF4D5E),
        selection: NSColor(hex: 0x22374F),
        ansi: [
            0x0E1520, 0xFF6B7A, 0x7EE0A8, 0xF2D479, 0x6CB6FF, 0xB9A2FF, 0x74E3F0, 0xC3CEDB,
            0x5A6B82, 0xFF97A1, 0xA6F0C4, 0xFFE6A3, 0x9CCEFF, 0xD2C4FF, 0xA4F0F7, 0xF0F6FF,
        ].map(NSColor.init(hex:))
    )

    static let amber = CodecTheme(
        id: "amber",
        name: "Amber",
        summary: "Warm dark brown with an amber accent.",
        isDark: true,
        background: NSColor(hex: 0x120B05),
        foreground: NSColor(hex: 0xF5D9B0),
        accent: NSColor(hex: 0xFFB347),
        alert: NSColor(hex: 0xFF4A3D),
        selection: NSColor(hex: 0x5A3A16),
        ansi: [
            0x1E140A, 0xFF6A4D, 0xB8D46A, 0xFFC857, 0x7FA8D9, 0xD98FB0, 0x7FC8B8, 0xE8D4B8,
            0x7D6649, 0xFF9478, 0xD2E88F, 0xFFDD8A, 0xA6C4E8, 0xEBB3CC, 0xA6E0D2, 0xFFF4E3,
        ].map(NSColor.init(hex:))
    )

    static let daylight = CodecTheme(
        id: "daylight",
        name: "Daylight",
        summary: "A light theme for bright rooms.",
        isDark: false,
        background: NSColor(hex: 0xF3F6F2),
        foreground: NSColor(hex: 0x1D2A24),
        accent: NSColor(hex: 0x0E8A55),
        alert: NSColor(hex: 0xE0243A),
        selection: NSColor(hex: 0xBFE3CF),
        ansi: [
            0x1D2A24, 0xC9283E, 0x1B8A4C, 0xA06A00, 0x1F5FBF, 0x8E3FA8, 0x0F7F86, 0x8A968F,
            0x56635C, 0xE04558, 0x23A85E, 0xC08A12, 0x3B7BDB, 0xA85CC2, 0x179AA2, 0xC9D1CC,
        ].map(NSColor.init(hex:))
    )
}

extension NSColor {
    /// `#rrggbb`.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    /// A 24-bit background color as SGR parameters, as zsh's completion colors take them.
    var sgrBackground: String {
        let c = usingColorSpace(.sRGB) ?? self
        return "48;2;\(Int(round(c.redComponent * 255)));\(Int(round(c.greenComponent * 255)));\(Int(round(c.blueComponent * 255)))"
    }

    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    var terminalColor: SwiftTerm.Color {
        let c = usingColorSpace(.sRGB) ?? self
        return SwiftTerm.Color(
            red: UInt16(c.redComponent * 65535),
            green: UInt16(c.greenComponent * 65535),
            blue: UInt16(c.blueComponent * 65535)
        )
    }
}
