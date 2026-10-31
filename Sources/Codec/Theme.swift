import AppKit
import SwiftTerm

/// A Codec colour scheme. Every theme is named after a place you'd rather not be stuck in without backup.
struct CodecTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let briefing: String
    let isDark: Bool
    let background: NSColor
    let foreground: NSColor
    /// Phosphor colour used for the frequency display, signal meters and caret.
    let accent: NSColor
    /// Colour of the "!" alert.
    let alert: NSColor
    let selection: NSColor
    /// The 16 ANSI colours: 8 normal followed by 8 bright.
    let ansi: [NSColor]

    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }
    var terminalPalette: [SwiftTerm.Color] { ansi.map(\.terminalColor) }

    static let all: [CodecTheme] = [.codec, .shadowMoses, .outerHeaven, .tanker]

    static func named(_ id: String) -> CodecTheme {
        all.first { $0.id == id } ?? .codec
    }
}

extension CodecTheme {
    static let codec = CodecTheme(
        id: "codec",
        name: "Codec",
        briefing: "Green phosphor. The classic frequency.",
        isDark: true,
        background: NSColor(hex: 0x06100B),
        foreground: NSColor(hex: 0xBDF5D3),
        accent: NSColor(hex: 0x52FFA8),
        alert: NSColor(hex: 0xFF3B4E),
        selection: NSColor(hex: 0x1D5C3E),
        ansi: [
            0x0B1A12, 0xFF5C6C, 0x4DE89A, 0xE6E07A, 0x5CB8FF, 0xC792EA, 0x4DE8D8, 0xB8D9C6,
            0x3D5C4B, 0xFF8A95, 0x8CFFC2, 0xFFF59E, 0x8FD0FF, 0xDDB6F2, 0x8CF5EA, 0xEAFFF3,
        ].map(NSColor.init(hex:))
    )

    static let shadowMoses = CodecTheme(
        id: "shadow-moses",
        name: "Shadow Moses",
        briefing: "Arctic night. Cold steel and blue ice.",
        isDark: true,
        background: NSColor(hex: 0x070B12),
        foreground: NSColor(hex: 0xC9D7E8),
        accent: NSColor(hex: 0x7FD4FF),
        alert: NSColor(hex: 0xFF4D5E),
        selection: NSColor(hex: 0x22374F),
        ansi: [
            0x0E1520, 0xFF6B7A, 0x7EE0A8, 0xF2D479, 0x6CB6FF, 0xB9A2FF, 0x74E3F0, 0xC3CEDB,
            0x3C4B5E, 0xFF97A1, 0xA6F0C4, 0xFFE6A3, 0x9CCEFF, 0xD2C4FF, 0xA4F0F7, 0xF0F6FF,
        ].map(NSColor.init(hex:))
    )

    static let outerHeaven = CodecTheme(
        id: "outer-heaven",
        name: "Outer Heaven",
        briefing: "Amber warning lights. A fortress of its own.",
        isDark: true,
        background: NSColor(hex: 0x120B05),
        foreground: NSColor(hex: 0xF5D9B0),
        accent: NSColor(hex: 0xFFB347),
        alert: NSColor(hex: 0xFF4A3D),
        selection: NSColor(hex: 0x5A3A16),
        ansi: [
            0x1E140A, 0xFF6A4D, 0xB8D46A, 0xFFC857, 0x7FA8D9, 0xD98FB0, 0x7FC8B8, 0xE8D4B8,
            0x5E4A33, 0xFF9478, 0xD2E88F, 0xFFDD8A, 0xA6C4E8, 0xEBB3CC, 0xA6E0D2, 0xFFF4E3,
        ].map(NSColor.init(hex:))
    )

    static let tanker = CodecTheme(
        id: "tanker",
        name: "Tanker",
        briefing: "Daylight on deck. For operatives who work in the open.",
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
