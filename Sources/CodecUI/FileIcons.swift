import AppKit
import CodecCore

/// Codec's file and folder icons, drawn from the theme's palette.
///
/// Every file is a small page with a folded corner, tinted like the prompt's chips: its color washed
/// over the background, outlined in the color itself. A monogram or a small glyph says what's inside.
/// Folders share the treatment and are colored by their role; the current one takes the accent.
@MainActor
enum FileIcons {
    static let size = NSSize(width: 16, height: 16)
    private static var cache: [String: NSImage] = [:]

    enum FolderState: String { case closed, open, current }

    static func image(for type: FileType, theme: CodecTheme) -> NSImage {
        cached("\(theme.id)|file|\(type.rawValue)") {
            let style = style(for: type, theme: theme)
            return draw { drawPage(color: style.color, theme: theme); drawMark(style.mark, color: style.color, center: CGPoint(x: 8, y: 9.4)) }
        }
    }

    static func image(for folder: FolderType, state: FolderState, theme: CodecTheme) -> NSImage {
        // The current folder is the accent whatever its role.
        cached("\(theme.id)|folder|\(state == .current ? "any" : folder.rawValue)|\(state.rawValue)") {
            let color = state == .current ? theme.accent : folderColor(folder, theme: theme)
            return draw { drawFolder(color: color, open: state != .closed, theme: theme) }
        }
    }

    private static func cached(_ key: String, make: () -> NSImage) -> NSImage {
        if let image = cache[key] { return image }
        let image = make()
        image.accessibilityDescription = nil
        cache[key] = image
        return image
    }

    private static func draw(_ body: @escaping () -> Void) -> NSImage {
        NSImage(size: size, flipped: true) { _ in
            body()
            return true
        }
    }

    // MARK: Colors

    private static func ansi(_ index: Int, _ theme: CodecTheme) -> NSColor { theme.ansi[index] }

    /// A neutral that reads on the theme's background.
    private static func neutral(_ theme: CodecTheme, _ amount: CGFloat = 0.62) -> NSColor {
        theme.background.blended(withFraction: amount, of: theme.foreground) ?? theme.foreground
    }

    private static func fill(_ color: NSColor, theme: CodecTheme, _ amount: CGFloat? = nil) -> NSColor {
        theme.background.blended(withFraction: amount ?? (theme.isDark ? 0.2 : 0.16), of: color) ?? color
    }

    private static func folderColor(_ folder: FolderType, theme: CodecTheme) -> NSColor {
        switch folder {
        case .plain: neutral(theme, 0.7)
        case .source: ansi(12, theme)
        case .tests: ansi(10, theme)
        case .docs: ansi(11, theme)
        case .assets: ansi(13, theme)
        case .scripts: ansi(14, theme)
        case .config: neutral(theme, 0.5)
        case .dependencies, .build: neutral(theme, 0.36)
        }
    }

    // MARK: Marks

    enum Mark: Equatable {
        case letters(String)
        case lines, indented, braces, angle, prompt, sliders, grid
        case picture, curve, bars, play, typeface
        case cube, padlock, containers, branch, key, check, info, zipper
    }

    private static func style(for type: FileType, theme: CodecTheme) -> (mark: Mark, color: NSColor) {
        let a = { (index: Int) in ansi(index, theme) }
        switch type {
        case .swift: return (.letters("SW"), a(9))
        case .javascript: return (.letters("JS"), a(3))
        case .typescript: return (.letters("TS"), a(4))
        case .python: return (.letters("PY"), a(6))
        case .ruby: return (.letters("RB"), a(1))
        case .go: return (.letters("GO"), a(14))
        case .rust: return (.letters("RS"), a(11))
        case .c: return (.letters("C"), a(12))
        case .cpp: return (.letters("C+"), a(12))
        case .objectiveC: return (.letters("OC"), a(12))
        case .java: return (.letters("JV"), a(9))
        case .kotlin: return (.letters("KT"), a(5))
        case .csharp: return (.letters("C#"), a(5))
        case .php: return (.letters("PH"), a(13))
        case .lua: return (.letters("LU"), a(4))
        case .sql: return (.letters("SQ"), a(6))
        case .html: return (.angle, a(9))
        case .css: return (.letters("#"), a(12))
        case .shell: return (.prompt, theme.accent)
        case .markdown: return (.letters("MD"), a(12))
        case .text: return (.lines, neutral(theme))
        case .pdf: return (.lines, a(1))
        case .json: return (.braces, a(3))
        case .yaml: return (.indented, a(5))
        case .toml: return (.indented, a(13))
        case .xml: return (.angle, a(14))
        case .config: return (.sliders, neutral(theme))
        case .log: return (.lines, neutral(theme, 0.45))
        case .csv: return (.grid, a(2))
        case .image: return (.picture, a(5))
        case .vector: return (.curve, a(13))
        case .audio: return (.bars, theme.accent)
        case .video: return (.play, a(13))
        case .font: return (.typeface, neutral(theme))
        case .manifest: return (.cube, a(11))
        case .lockfile: return (.padlock, neutral(theme, 0.5))
        case .docker: return (.containers, a(12))
        case .git: return (.branch, a(9))
        case .environment: return (.key, a(3))
        case .license: return (.check, a(11))
        case .readme: return (.info, a(4))
        case .archive: return (.zipper, a(3))
        case .binary: return (.letters("01"), neutral(theme, 0.5))
        case .other: return (.lines, neutral(theme, 0.45))
        }
    }

    /// The mark a type is drawn with, for tests.
    static func mark(for type: FileType) -> Mark { style(for: type, theme: .codec).mark }

    // MARK: Drawing

    /// A page with its top-right corner folded over.
    private static func drawPage(color: NSColor, theme: CodecTheme) {
        let left: CGFloat = 2.5, right: CGFloat = 13.5, top: CGFloat = 1.5, bottom: CGFloat = 14.5
        let fold: CGFloat = 3.5, radius: CGFloat = 1.8
        let page = NSBezierPath()
        page.move(to: CGPoint(x: left + radius, y: top))
        page.line(to: CGPoint(x: right - fold, y: top))
        page.line(to: CGPoint(x: right, y: top + fold))
        page.line(to: CGPoint(x: right, y: bottom - radius))
        page.appendArc(from: CGPoint(x: right, y: bottom), to: CGPoint(x: right - radius, y: bottom), radius: radius)
        page.line(to: CGPoint(x: left + radius, y: bottom))
        page.appendArc(from: CGPoint(x: left, y: bottom), to: CGPoint(x: left, y: bottom - radius), radius: radius)
        page.line(to: CGPoint(x: left, y: top + radius))
        page.appendArc(from: CGPoint(x: left, y: top), to: CGPoint(x: left + radius, y: top), radius: radius)
        page.close()
        fill(color, theme: theme).setFill()
        page.fill()
        color.withAlphaComponent(0.8).setStroke()
        page.lineWidth = 1
        page.lineJoinStyle = .round
        page.stroke()

        let flap = NSBezierPath()
        flap.move(to: CGPoint(x: right - fold, y: top))
        flap.line(to: CGPoint(x: right - fold, y: top + fold))
        flap.line(to: CGPoint(x: right, y: top + fold))
        flap.close()
        fill(color, theme: theme, theme.isDark ? 0.45 : 0.35).setFill()
        flap.fill()
        flap.lineWidth = 1
        flap.lineJoinStyle = .round
        flap.stroke()
    }

    private static func drawFolder(color: NSColor, open: Bool, theme: CodecTheme) {
        let tab = NSBezierPath()
        tab.move(to: CGPoint(x: 1.5, y: 4.5))
        tab.line(to: CGPoint(x: 1.5, y: 3.5))
        tab.appendArc(from: CGPoint(x: 1.5, y: 2.5), to: CGPoint(x: 2.5, y: 2.5), radius: 1)
        tab.line(to: CGPoint(x: 5.6, y: 2.5))
        tab.line(to: CGPoint(x: 7.1, y: 4.5))
        let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4.5, width: 13, height: 9), xRadius: 1.8, yRadius: 1.8)
        fill(color, theme: theme).setFill()
        tab.fill()
        body.fill()
        color.withAlphaComponent(0.85).setStroke()
        for path in [tab, body] {
            path.lineWidth = 1
            path.lineJoinStyle = .round
            path.stroke()
        }
        if open {
            // The front cover, tipped forward.
            let front = NSBezierPath()
            front.move(to: CGPoint(x: 3.6, y: 7.5))
            front.line(to: CGPoint(x: 15.3, y: 7.5))
            front.line(to: CGPoint(x: 13.4, y: 13.5))
            front.line(to: CGPoint(x: 1.5, y: 13.5))
            front.close()
            fill(color, theme: theme, theme.isDark ? 0.42 : 0.32).setFill()
            front.fill()
            front.lineWidth = 1
            front.lineJoinStyle = .round
            front.stroke()
        } else {
            // A seam under the tab, so closed folders read as folders at a glance.
            let seam = NSBezierPath()
            seam.move(to: CGPoint(x: 2, y: 6.5))
            seam.line(to: CGPoint(x: 14, y: 6.5))
            color.withAlphaComponent(0.35).setStroke()
            seam.lineWidth = 1
            seam.stroke()
        }
    }

    private static func stroke(_ path: NSBezierPath, _ color: NSColor, width: CGFloat = 1.1) {
        color.setStroke()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func line(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach(path.line(to:))
        return path
    }

    private static func text(_ string: String, size: CGFloat, color: NSColor, center: CGPoint, kern: CGFloat = -0.2) {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .heavy)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: kern])
        let bounds = attributed.size()
        attributed.draw(at: CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2))
    }

    // Marks are drawn in the 9 × 9 square around `center` (y down).
    private static func drawMark(_ mark: Mark, color: NSColor, center c: CGPoint) {
        let x = c.x, y = c.y
        switch mark {
        case .letters(let letters):
            text(letters, size: letters.count > 1 ? 7 : 8.4, color: color, center: CGPoint(x: x - 0.2, y: y + 0.2),
                 kern: letters.count > 1 ? -0.6 : 0)
        case .lines:
            for (row, length) in [(-2.5, 5.0), (0, 6.0), (2.5, 3.5)] {
                stroke(line([CGPoint(x: x - 3, y: y + row), CGPoint(x: x - 3 + length, y: y + row)]), color)
            }
        case .indented:
            for (row, indent, length) in [(-2.5, 0.0, 4.0), (0, 2.0, 4.0), (2.5, 2.0, 3.0)] {
                stroke(line([CGPoint(x: x - 3 + indent, y: y + row), CGPoint(x: x - 3 + indent + length, y: y + row)]), color)
            }
        case .braces:
            text("{}", size: 7, color: color, center: CGPoint(x: x, y: y))
        case .angle:
            stroke(line([CGPoint(x: x - 1.2, y: y - 2.8), CGPoint(x: x - 3.6, y: y), CGPoint(x: x - 1.2, y: y + 2.8)]), color)
            stroke(line([CGPoint(x: x + 1.2, y: y - 2.8), CGPoint(x: x + 3.6, y: y), CGPoint(x: x + 1.2, y: y + 2.8)]), color)
        case .prompt:
            stroke(line([CGPoint(x: x - 3.4, y: y - 2.6), CGPoint(x: x - 0.8, y: y), CGPoint(x: x - 3.4, y: y + 2.6)]), color, width: 1.3)
            stroke(line([CGPoint(x: x + 0.6, y: y + 2.6), CGPoint(x: x + 3.6, y: y + 2.6)]), color, width: 1.3)
        case .sliders:
            for (row, knob) in [(-2.2, 1.2), (2.2, -1.4)] {
                stroke(line([CGPoint(x: x - 3.4, y: y + row), CGPoint(x: x + 3.4, y: y + row)]), color.withAlphaComponent(0.6), width: 1)
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x + knob - 1.4, y: y + row - 1.4, width: 2.8, height: 2.8)).fill()
            }
        case .grid:
            let frame = NSBezierPath(rect: NSRect(x: x - 3.5, y: y - 3, width: 7, height: 6))
            stroke(frame, color, width: 0.9)
            stroke(line([CGPoint(x: x - 3.5, y: y), CGPoint(x: x + 3.5, y: y)]), color, width: 0.9)
            stroke(line([CGPoint(x: x, y: y - 3), CGPoint(x: x, y: y + 3)]), color, width: 0.9)
        case .picture:
            stroke(line([CGPoint(x: x - 3.8, y: y + 3), CGPoint(x: x - 1, y: y - 0.6), CGPoint(x: x + 0.8, y: y + 1.2),
                         CGPoint(x: x + 2, y: y), CGPoint(x: x + 3.8, y: y + 3)]), color)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 1, y: y - 3.6, width: 2.4, height: 2.4)).fill()
        case .curve:
            let curve = NSBezierPath()
            curve.move(to: CGPoint(x: x - 3.4, y: y + 3))
            curve.curve(to: CGPoint(x: x + 3.4, y: y - 3), controlPoint1: CGPoint(x: x - 3, y: y - 3.5), controlPoint2: CGPoint(x: x + 3, y: y + 3.5))
            stroke(curve, color)
            color.setFill()
            for point in [CGPoint(x: x - 3.4, y: y + 3), CGPoint(x: x + 3.4, y: y - 3)] {
                NSBezierPath(rect: NSRect(x: point.x - 1.1, y: point.y - 1.1, width: 2.2, height: 2.2)).fill()
            }
        case .bars:
            // The codec's signal meter.
            color.setFill()
            for (index, height) in [2.5, 4.5, 3.5, 6.5].enumerated() {
                let left = x - 3.7 + CGFloat(index) * 2.1
                NSBezierPath(roundedRect: NSRect(x: left, y: y + 3.2 - height, width: 1.3, height: height), xRadius: 0.4, yRadius: 0.4).fill()
            }
        case .play:
            let triangle = line([CGPoint(x: x - 2, y: y - 3), CGPoint(x: x + 3, y: y), CGPoint(x: x - 2, y: y + 3)])
            triangle.close()
            color.setFill()
            triangle.fill()
        case .typeface:
            text("Aa", size: 6.4, color: color, center: CGPoint(x: x, y: y))
        case .cube:
            let top = line([CGPoint(x: x, y: y - 3.6), CGPoint(x: x + 3.4, y: y - 1.8), CGPoint(x: x, y: y), CGPoint(x: x - 3.4, y: y - 1.8)])
            top.close()
            stroke(top, color, width: 1)
            stroke(line([CGPoint(x: x - 3.4, y: y - 1.8), CGPoint(x: x - 3.4, y: y + 1.8), CGPoint(x: x, y: y + 3.6),
                         CGPoint(x: x + 3.4, y: y + 1.8), CGPoint(x: x + 3.4, y: y - 1.8)]), color, width: 1)
            stroke(line([CGPoint(x: x, y: y), CGPoint(x: x, y: y + 3.6)]), color, width: 1)
        case .padlock:
            let shackle = NSBezierPath()
            shackle.appendArc(withCenter: CGPoint(x: x, y: y - 1), radius: 2, startAngle: 180, endAngle: 0, clockwise: false)
            stroke(shackle, color, width: 1.1)
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 3, y: y - 1, width: 6, height: 4.4), xRadius: 0.8, yRadius: 0.8).fill()
        case .containers:
            color.setFill()
            for (column, row) in [(-1, 0), (0, 0), (1, 0), (0, -1)] {
                NSBezierPath(roundedRect: NSRect(x: x - 1.15 + CGFloat(column) * 2.6, y: y + 0.4 + CGFloat(row) * 2.6, width: 2.2, height: 2.2),
                             xRadius: 0.3, yRadius: 0.3).fill()
            }
        case .branch:
            stroke(line([CGPoint(x: x - 2, y: y - 3), CGPoint(x: x - 2, y: y + 3)]), color)
            let fork = NSBezierPath()
            fork.move(to: CGPoint(x: x + 2.2, y: y - 1.6))
            fork.curve(to: CGPoint(x: x - 2, y: y + 1.6), controlPoint1: CGPoint(x: x + 2.2, y: y + 0.6), controlPoint2: CGPoint(x: x - 2, y: y))
            stroke(fork, color)
            color.setFill()
            for point in [CGPoint(x: x - 2, y: y - 3), CGPoint(x: x - 2, y: y + 3), CGPoint(x: x + 2.2, y: y - 2)] {
                NSBezierPath(ovalIn: NSRect(x: point.x - 1.2, y: point.y - 1.2, width: 2.4, height: 2.4)).fill()
            }
        case .key:
            stroke(NSBezierPath(ovalIn: NSRect(x: x - 3.8, y: y - 3.2, width: 3.6, height: 3.6)), color)
            stroke(line([CGPoint(x: x - 0.7, y: y - 0.1), CGPoint(x: x + 3.2, y: y + 3.4)]), color)
            stroke(line([CGPoint(x: x + 1.6, y: y + 1.9), CGPoint(x: x + 2.6, y: y + 0.9)]), color)
        case .check:
            stroke(line([CGPoint(x: x - 3.2, y: y + 0.2), CGPoint(x: x - 0.8, y: y + 2.6), CGPoint(x: x + 3.4, y: y - 2.6)]), color, width: 1.4)
        case .info:
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 0.9, y: y - 3.6, width: 1.8, height: 1.8)).fill()
            stroke(line([CGPoint(x: x, y: y - 0.6), CGPoint(x: x, y: y + 3.2)]), color, width: 1.5)
        case .zipper:
            for step in 0..<4 {
                let row = y - 3.4 + CGFloat(step) * 1.9
                let side: CGFloat = step.isMultiple(of: 2) ? -1 : 0
                color.setFill()
                NSBezierPath(rect: NSRect(x: x + side, y: row, width: 1.2, height: 1.1)).fill()
            }
            NSBezierPath(roundedRect: NSRect(x: x - 1.3, y: y + 2.2, width: 2.6, height: 2), xRadius: 0.5, yRadius: 0.5).fill()
        }
    }
}
