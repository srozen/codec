import CoreText
import Foundation
import SwiftTerm
import CodecCore

/// Glyphs Codec draws in the terminal whatever font is chosen: the panel prompt's LCD digits
/// (U+1FBF0–U+1FBF9) and its corners (⌈ ⌋). They come from a small TrueType font built here, in memory,
/// which SwiftTerm falls back to when the terminal's font doesn't have them; a font that does keeps its own.
///
/// CoreText fonts and descriptors are immutable and safe to share between threads; the cache is behind a lock.
final class CodecGlyphs: TerminalGlyphFallbackProvider, @unchecked Sendable {
    static let shared = CodecGlyphs()

    let generation: UInt64 = 1
    private let descriptor: CTFontDescriptor?
    private let lock = NSLock()
    private var fonts: [CGFloat: CTFont] = [:]

    private init() {
        descriptor = CTFontManagerCreateFontDescriptorFromData(GlyphFont.data as CFData)
    }

    func placementPolicy(for scalar: Unicode.Scalar) -> TerminalGlyphPlacementPolicy? {
        GlyphFont.policies[scalar]
    }

    func fallbackFont(forPointSize size: CGFloat) -> CTFont? {
        guard let descriptor else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let font = fonts[size] { return font }
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        fonts[size] = font
        return font
    }
}

/// The font's outlines, how each is placed in its cell, and the TrueType file that holds them.
enum GlyphFont {
    typealias Point = (x: Int, y: Int)

    struct Glyph {
        let scalar: Unicode.Scalar
        /// Closed polygons, clockwise, in font units.
        let contours: [[Point]]
        let policy: TerminalGlyphPlacementPolicy

        var bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int) {
            let points = contours.flatMap { $0 }
            return (points.map(\.x).min() ?? 0, points.map(\.y).min() ?? 0,
                    points.map(\.x).max() ?? 0, points.map(\.y).max() ?? 0)
        }
    }

    static let unitsPerEm = 1000
    static let advance = 600
    static let ascender = 800
    static let descender = -200

    // MARK: LCD digits

    /// The box every digit is drawn in: a little taller than a capital, as LCD digits read smaller than
    /// type of the same height. Strokes are heavy enough that a lone 1 still reads at small sizes.
    static let digitBox = (x: 75, width: 450, height: 740)
    private static let stroke = 84
    private static let gap = 16

    /// One segment, a stretched hexagon whose pointed ends leave a thin gap to its neighbours.
    private static func segment(_ name: Character) -> [Point] {
        let half = stroke / 2, width = digitBox.width, height = digitBox.height
        let left = half, right = width - half, bottom = half, middle = height / 2, top = height - half
        func horizontal(_ y: Int) -> [Point] {
            let x0 = left + gap, x1 = right - gap
            return [(x0, y), (x0 + half, y + half), (x1 - half, y + half), (x1, y), (x1 - half, y - half), (x0 + half, y - half)]
        }
        func vertical(_ x: Int, from low: Int, to high: Int) -> [Point] {
            let y0 = low + gap, y1 = high - gap
            return [(x, y0), (x - half, y0 + half), (x - half, y1 - half), (x, y1), (x + half, y1 - half), (x + half, y0 + half)]
        }
        let points = switch name {
        case "a": horizontal(top)
        case "g": horizontal(middle)
        case "d": horizontal(bottom)
        case "f": vertical(left, from: middle, to: top)
        case "b": vertical(right, from: middle, to: top)
        case "e": vertical(left, from: bottom, to: middle)
        default: vertical(right, from: bottom, to: middle)
        }
        return points.map { ($0.x + digitBox.x, $0.y) }
    }

    private static func digit(_ value: Int) -> Glyph {
        let lit = SevenSegment.map[Character(String(value))] ?? ""
        let contours = "abcdefg".filter(lit.contains).map(segment)
        let ink = contours.flatMap { $0 }
        let minX = ink.map(\.x).min()!, maxX = ink.map(\.x).max()!
        let minY = ink.map(\.y).min()!, maxY = ink.map(\.y).max()!
        let box = digitBox
        // Fitted as a group, so a 1 keeps its place on the right of an 8's box instead of filling the cell.
        let relative = CGRect(x: CGFloat(minX - box.x) / CGFloat(box.width), y: CGFloat(minY) / CGFloat(box.height),
                              width: CGFloat(maxX - minX) / CGFloat(box.width), height: CGFloat(maxY - minY) / CGFloat(box.height))
        return Glyph(scalar: PromptConfiguration.lcdDigits[value].unicodeScalars.first!, contours: contours,
                     policy: TerminalGlyphPlacementPolicy(placement: .grouped, relativeBounds: relative,
                                                         // Centered in the cell they sit high: this brings them down onto the baseline.
                                                         padding: TerminalGlyphPadding(top: 0.08)))
    }

    // MARK: Corners

    /// The panel's corners are stretched over part of their cell so they meet its edges: the opening one
    /// sits in the top-left, the closing one in the bottom-right, and the line between them reads as a box.
    /// Arms are drawn thicker across than down, as stretching thins them more across.
    private static let corners: [Glyph] = {
        let (open, close) = PromptConfiguration.panelCorners
        let top = ascender, bottom = descender
        let opening: [Point] = [(25, top - 400), (25, top), (575, top), (575, top - 70), (165, top - 70), (165, top - 400)]
        let closing: [Point] = [(25, bottom), (25, bottom + 70), (435, bottom + 70), (435, bottom + 400), (575, bottom + 400), (575, bottom)]
        return [
            Glyph(scalar: open.unicodeScalars.first!, contours: [opening],
                  policy: TerminalGlyphPlacementPolicy(placement: .stretch, padding: TerminalGlyphPadding(bottom: 0.62, right: 0.5))),
            Glyph(scalar: close.unicodeScalars.first!, contours: [closing],
                  policy: TerminalGlyphPlacementPolicy(placement: .stretch, padding: TerminalGlyphPadding(top: 0.62, left: 0.5))),
        ]
    }()

    /// In glyph order; glyph 0 is the empty `.notdef`.
    static let glyphs: [Glyph] = (0...9).map(digit) + corners

    static let policies: [Unicode.Scalar: TerminalGlyphPlacementPolicy] =
        Dictionary(uniqueKeysWithValues: glyphs.map { ($0.scalar, $0.policy) })

    // MARK: TrueType

    static let data: Data = trueType()

    private static func trueType() -> Data {
        let all = [Glyph?.none] + glyphs.map(Optional.some)
        let bounds = glyphs.map(\.bounds)
        let fontMinX = bounds.map(\.minX).min()!, fontMinY = bounds.map(\.minY).min()!
        let fontMaxX = bounds.map(\.maxX).max()!, fontMaxY = bounds.map(\.maxY).max()!

        var glyf = BigEndian(), loca = BigEndian(), hmtx = BigEndian()
        for glyph in all {
            loca.u32(glyf.data.count)
            let bounds = glyph?.bounds ?? (minX: 0, minY: 0, maxX: 0, maxY: 0)
            hmtx.u16(advance)
            hmtx.i16(bounds.minX)
            guard let glyph else { continue }
            glyf.i16(glyph.contours.count)
            glyf.i16(bounds.minX); glyf.i16(bounds.minY); glyf.i16(bounds.maxX); glyf.i16(bounds.maxY)
            var end = -1
            for contour in glyph.contours {
                end += contour.count
                glyf.u16(end)
            }
            glyf.u16(0) // no instructions
            let points = glyph.contours.flatMap { $0 }
            for _ in points { glyf.u8(0x01) } // on the curve, coordinates as 16-bit deltas
            var previous = (x: 0, y: 0)
            for point in points { glyf.i16(point.x - previous.x); previous.x = point.x }
            for point in points { glyf.i16(point.y - previous.y); previous.y = point.y }
            glyf.pad()
        }
        loca.u32(glyf.data.count)

        var head = BigEndian()
        head.u32(0x0001_0000); head.u32(0x0001_0000)
        head.u32(0) // checkSumAdjustment, filled in once the whole font is laid out
        head.u32(0x5F0F_3CF5)
        head.u16(0x0009) // baseline at y = 0, integer scaling
        head.u16(unitsPerEm)
        head.u32(0); head.u32(0); head.u32(0); head.u32(0) // created and modified
        head.i16(fontMinX); head.i16(fontMinY); head.i16(fontMaxX); head.i16(fontMaxY)
        head.u16(0); head.u16(6); head.i16(2)
        head.i16(1) // long loca offsets
        head.i16(0)

        var hhea = BigEndian()
        hhea.u32(0x0001_0000)
        hhea.i16(ascender); hhea.i16(descender); hhea.i16(0)
        hhea.u16(advance)
        hhea.i16(fontMinX); hhea.i16(advance - fontMaxX); hhea.i16(fontMaxX)
        hhea.i16(1); hhea.i16(0); hhea.i16(0)
        for _ in 0..<4 { hhea.i16(0) }
        hhea.i16(0)
        hhea.u16(all.count)

        let points = glyphs.map { $0.contours.reduce(0) { $0 + $1.count } }
        var maxp = BigEndian()
        maxp.u32(0x0001_0000)
        maxp.u16(all.count)
        maxp.u16(points.max()!)
        maxp.u16(glyphs.map(\.contours.count).max()!)
        maxp.u16(0); maxp.u16(0)
        maxp.u16(2) // zones
        for _ in 0..<8 { maxp.u16(0) }

        var os2 = BigEndian()
        os2.u16(4)
        os2.i16(advance); os2.u16(400); os2.u16(5); os2.u16(0)
        for value in [650, 600, 0, 75, 650, 600, 0, 350] { os2.i16(value) }
        os2.i16(50); os2.i16(300); os2.i16(0)
        for _ in 0..<10 { os2.u8(0) } // PANOSE
        for _ in 0..<4 { os2.u32(0) } // Unicode ranges
        os2.tag("CDEC")
        os2.u16(0x0040) // regular
        os2.u16(Int(glyphs.map(\.scalar.value).min()!)); os2.u16(0xFFFF)
        os2.i16(ascender); os2.i16(descender); os2.i16(0)
        os2.u16(ascender); os2.u16(-descender)
        os2.u32(0); os2.u32(0)
        os2.i16(500); os2.i16(digitBox.height)
        os2.u16(0); os2.u16(32); os2.u16(0)

        // One format 12 table, which reaches beyond the Basic Multilingual Plane, for both Unicode encodings.
        let mapped = glyphs.enumerated().map { (scalar: $0.element.scalar.value, glyph: $0.offset + 1) }
            .sorted { $0.scalar < $1.scalar }
        var cmap = BigEndian()
        cmap.u16(0); cmap.u16(2)
        cmap.u16(0); cmap.u16(4); cmap.u32(20)
        cmap.u16(3); cmap.u16(10); cmap.u32(20)
        cmap.u16(12); cmap.u16(0)
        cmap.u32(16 + 12 * mapped.count)
        cmap.u32(0)
        cmap.u32(mapped.count)
        for entry in mapped {
            cmap.u32(Int(entry.scalar)); cmap.u32(Int(entry.scalar)); cmap.u32(entry.glyph)
        }

        let names = [(1, "Codec Glyphs"), (2, "Regular"), (3, "Codec Glyphs 1.0"), (4, "Codec Glyphs"), (6, "CodecGlyphs-Regular")]
        var name = BigEndian(), strings = BigEndian()
        name.u16(0); name.u16(names.count); name.u16(6 + 12 * names.count)
        for (id, text) in names {
            let utf16 = Array(text.utf16)
            name.u16(3); name.u16(1); name.u16(0x0409); name.u16(id)
            name.u16(utf16.count * 2); name.u16(strings.data.count)
            utf16.forEach { strings.u16(Int($0)) }
        }
        name.data.append(strings.data)

        var post = BigEndian()
        post.u32(0x0003_0000); post.u32(0)
        post.i16(-100); post.i16(50)
        post.u32(1) // monospaced
        for _ in 0..<4 { post.u32(0) }

        return assemble([("OS/2", os2), ("cmap", cmap), ("glyf", glyf), ("head", head), ("hhea", hhea),
                         ("hmtx", hmtx), ("loca", loca), ("maxp", maxp), ("name", name), ("post", post)])
    }

    /// Lays out the table directory and tables (sorted by tag), and sets head's checksum adjustment.
    private static func assemble(_ tables: [(tag: String, table: BigEndian)]) -> Data {
        var power = 1
        while power * 2 <= tables.count { power *= 2 }
        var font = BigEndian()
        font.u32(0x0001_0000)
        font.u16(tables.count)
        font.u16(power * 16); font.u16(power.trailingZeroBitCount); font.u16(tables.count * 16 - power * 16)
        var offset = 12 + 16 * tables.count
        var body = BigEndian()
        var headOffset = 0
        for (tag, table) in tables {
            var padded = table
            padded.pad()
            font.tag(tag)
            font.u32(Int(checksum(padded.data)))
            font.u32(offset)
            font.u32(table.data.count)
            if tag == "head" { headOffset = offset }
            body.data.append(padded.data)
            offset += padded.data.count
        }
        var data = font.data + body.data
        let adjustment = 0xB1B0_AFBA &- checksum(data)
        withUnsafeBytes(of: adjustment.bigEndian) { data.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: $0) }
        return data
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        var index = data.startIndex
        while index < data.endIndex {
            var word: UInt32 = 0
            for byte in 0..<4 {
                let at = index + byte
                word = word << 8 | UInt32(at < data.endIndex ? data[at] : 0)
            }
            sum &+= word
            index += 4
        }
        return sum
    }
}

/// Big-endian binary data, as TrueType stores it.
private struct BigEndian {
    var data = Data()

    mutating func u8(_ value: Int) { data.append(UInt8(truncatingIfNeeded: value)) }
    mutating func u16(_ value: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).bigEndian) { data.append(contentsOf: $0) } }
    mutating func i16(_ value: Int) { u16(Int(Int16(value))) }
    mutating func u32(_ value: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).bigEndian) { data.append(contentsOf: $0) } }
    mutating func tag(_ text: String) { data.append(contentsOf: Array(text.utf8.prefix(4))) }
    /// Pads to a multiple of four bytes, which glyphs and tables are aligned to.
    mutating func pad() { while data.count % 4 != 0 { data.append(0) } }
}
