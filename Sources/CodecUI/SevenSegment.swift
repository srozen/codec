import SwiftUI

/// Segment geometry for an LCD-style seven-segment readout, used by the status bar meters.
///
///      a
///    f   b
///      g
///    e   c
///      d
enum SevenSegment {
    struct Glyph {
        var segments: Set<Character>
        var dot: Bool
    }

    static let all: Set<Character> = ["a", "b", "c", "d", "e", "f", "g"]

    static let map: [Character: String] = [
        "0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg",
        "5": "acdfg", "6": "acdefg", "7": "abc", "8": "abcdefg", "9": "abcdfg",
        "-": "g", "_": "d", " ": "",
        "A": "abcefg", "C": "adef", "E": "adefg", "F": "aefg", "H": "bcefg",
        "L": "def", "N": "abcef", "O": "abcdef", "P": "abefg", "S": "acdfg",
        "T": "defg", "U": "bcdef", "Y": "bcdfg",
    ]

    /// Splits text into glyphs, folding each "." onto the digit before it the way real displays do.
    static func glyphs(_ text: String) -> [Glyph] {
        var result: [Glyph] = []
        for ch in text.uppercased() {
            if ch == "." {
                if result.isEmpty || result[result.count - 1].dot {
                    result.append(Glyph(segments: [], dot: true))
                } else {
                    result[result.count - 1].dot = true
                }
            } else {
                result.append(Glyph(segments: Set(map[ch] ?? ""), dot: false))
            }
        }
        return result
    }

    static let digitWidth: CGFloat = 0.56
    static let spacing: CGFloat = 0.2
    static let slant: CGFloat = 0.09

    static func aspectRatio(for text: String) -> CGFloat {
        let n = CGFloat(max(glyphs(text).count, 1))
        return n * digitWidth + (n - 1) * spacing + slant
    }

    /// Paths for one glyph cell of height `h`, keyed by segment name.
    static func segmentPaths(height h: CGFloat) -> [Character: Path] {
        let w = h * digitWidth
        let t = h * 0.13
        let g = t * 0.24
        let left = t / 2, right = w - t / 2
        let top = t / 2, mid = h / 2, bottom = h - t / 2

        func horizontal(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> Path {
            Path { p in
                p.move(to: CGPoint(x: x0, y: y))
                p.addLine(to: CGPoint(x: x0 + t / 2, y: y - t / 2))
                p.addLine(to: CGPoint(x: x1 - t / 2, y: y - t / 2))
                p.addLine(to: CGPoint(x: x1, y: y))
                p.addLine(to: CGPoint(x: x1 - t / 2, y: y + t / 2))
                p.addLine(to: CGPoint(x: x0 + t / 2, y: y + t / 2))
                p.closeSubpath()
            }
        }
        func vertical(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> Path {
            Path { p in
                p.move(to: CGPoint(x: x, y: y0))
                p.addLine(to: CGPoint(x: x + t / 2, y: y0 + t / 2))
                p.addLine(to: CGPoint(x: x + t / 2, y: y1 - t / 2))
                p.addLine(to: CGPoint(x: x, y: y1))
                p.addLine(to: CGPoint(x: x - t / 2, y: y1 - t / 2))
                p.addLine(to: CGPoint(x: x - t / 2, y: y0 + t / 2))
                p.closeSubpath()
            }
        }
        return [
            "a": horizontal(left + g, right - g, top),
            "b": vertical(right, top + g, mid - g),
            "c": vertical(right, mid + g, bottom - g),
            "d": horizontal(left + g, right - g, bottom),
            "e": vertical(left, mid + g, bottom - g),
            "f": vertical(left, top + g, mid - g),
            "g": horizontal(left + g, right - g, mid),
        ]
    }

    static func dotPath(height h: CGFloat) -> Path {
        let w = h * digitWidth
        let size = h * 0.13
        let x = w + (h * spacing - size) / 2
        return Path(CGRect(x: x, y: h - size, width: size, height: size))
    }
}

/// Renders text as a glowing seven-segment display, with unlit "ghost" segments behind it.
struct SevenSegmentDisplay: View {
    var text: String
    var color: Color
    var ghost: Double = 0.1
    var glow: CGFloat = 0.35

    var body: some View {
        Canvas { context, size in
            let h = size.height
            let glyphs = SevenSegment.glyphs(text)
            let paths = SevenSegment.segmentPaths(height: h)
            let dot = SevenSegment.dotPath(height: h)
            let step = h * (SevenSegment.digitWidth + SevenSegment.spacing)
            let skew = CGAffineTransform(a: 1, b: 0, c: -SevenSegment.slant, d: 1, tx: SevenSegment.slant * h, ty: 0)

            var lit = Path()
            var unlit = Path()
            for (i, glyph) in glyphs.enumerated() {
                let place = skew.concatenating(CGAffineTransform(translationX: CGFloat(i) * step, y: 0))
                for (name, path) in paths {
                    if glyph.segments.contains(name) {
                        lit.addPath(path, transform: place)
                    } else {
                        unlit.addPath(path, transform: place)
                    }
                }
                if glyph.dot {
                    lit.addPath(dot, transform: place)
                } else {
                    unlit.addPath(dot, transform: place)
                }
            }

            context.fill(unlit, with: .color(color.opacity(ghost)))
            if glow > 0 {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: color.opacity(0.9), radius: h * glow))
                    layer.fill(lit, with: .color(color))
                }
            } else {
                context.fill(lit, with: .color(color))
            }
        }
        .aspectRatio(SevenSegment.aspectRatio(for: text), contentMode: .fit)
        .accessibilityLabel(text)
    }
}

/// The codec's rising signal-strength bars.
struct SignalMeter: View {
    var level: Double
    var color: Color
    var bars = 6
    var mirrored = false

    var body: some View {
        Canvas { context, size in
            let gap = size.width * 0.07
            let barWidth = (size.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
            let lit = Int((level * Double(bars)).rounded(.up))
            for i in 0..<bars {
                let index = mirrored ? bars - 1 - i : i
                let height = size.height * (0.3 + 0.7 * CGFloat(index + 1) / CGFloat(bars))
                let rect = CGRect(
                    x: CGFloat(i) * (barWidth + gap),
                    y: size.height - height,
                    width: barWidth,
                    height: height
                )
                let on = index < lit
                context.fill(Path(rect), with: .color(color.opacity(on ? 1 : 0.16)))
            }
        }
        .accessibilityHidden(true)
    }
}
