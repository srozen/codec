// Renders Codec's app icon to a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Work in a y-down space.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let phosphor: UInt32 = 0x52FFA8
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Tile with drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(squircle)
ctx.setFillColor(rgb(0x04120B))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Deep green body.
let body = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                      colors: [rgb(0x0E3A27), rgb(0x061A10), rgb(0x020A06)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(body, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])

// Phosphor bloom behind the readout.
let bloom = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [rgb(phosphor, 0.22), rgb(phosphor, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 420, options: [])

// Scanlines.
ctx.setFillColor(rgb(0x000000, 0.22))
var y = tile.minY
while y < tile.maxY {
    ctx.fill(CGRect(x: tile.minX, y: y, width: tile.width, height: 4))
    y += 11
}

// Seven-segment "140.85".
func segments(for ch: Character) -> String {
    ["0": "abcdef", "1": "bc", "4": "bcfg", "5": "acdfg", "8": "abcdefg"][ch] ?? ""
}

func digitPaths(h: CGFloat) -> [Character: CGPath] {
    let w = h * 0.56, t = h * 0.14, g = t * 0.24
    let left = t / 2, right = w - t / 2, top = t / 2, mid = h / 2, bottom = h - t / 2
    func hz(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: x0, y: y), CGPoint(x: x0 + t / 2, y: y - t / 2), CGPoint(x: x1 - t / 2, y: y - t / 2),
                             CGPoint(x: x1, y: y), CGPoint(x: x1 - t / 2, y: y + t / 2), CGPoint(x: x0 + t / 2, y: y + t / 2)])
        p.closeSubpath()
        return p
    }
    func vt(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: x, y: y0), CGPoint(x: x + t / 2, y: y0 + t / 2), CGPoint(x: x + t / 2, y: y1 - t / 2),
                             CGPoint(x: x, y: y1), CGPoint(x: x - t / 2, y: y1 - t / 2), CGPoint(x: x - t / 2, y: y0 + t / 2)])
        p.closeSubpath()
        return p
    }
    return ["a": hz(left + g, right - g, top), "b": vt(right, top + g, mid - g), "c": vt(right, mid + g, bottom - g),
            "d": hz(left + g, right - g, bottom), "e": vt(left, mid + g, bottom - g), "f": vt(left, top + g, mid - g),
            "g": hz(left + g, right - g, mid)]
}

let digitHeight: CGFloat = 150
let digits = Array("14085")
let step = digitHeight * 0.76
let readoutWidth = CGFloat(digits.count) * step - digitHeight * 0.2
let origin = CGPoint(x: 512 - readoutWidth / 2 - 8, y: 250)
let paths = digitPaths(h: digitHeight)
let lit = CGMutablePath(), ghost = CGMutablePath()
for (i, ch) in digits.enumerated() {
    let on = segments(for: ch)
    var transform = CGAffineTransform(a: 1, b: 0, c: -0.09, d: 1, tx: origin.x + CGFloat(i) * step + 0.09 * digitHeight, ty: origin.y)
    for (name, path) in paths {
        if on.contains(name) { lit.addPath(path, transform: transform) } else { ghost.addPath(path, transform: transform) }
    }
    if i == 2 {
        let dot = CGPath(rect: CGRect(x: digitHeight * 0.56 + 4, y: digitHeight - 21, width: 21, height: 21), transform: &transform)
        lit.addPath(dot)
    }
}
ctx.addPath(ghost)
ctx.setFillColor(rgb(phosphor, 0.08))
ctx.fillPath()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 36, color: rgb(phosphor, 0.95))
ctx.addPath(lit)
ctx.setFillColor(rgb(phosphor))
ctx.fillPath()
ctx.restoreGState()

// Rising signal bars.
let bars = 6
let barArea = CGRect(x: 250, y: 500, width: 524, height: 300)
let gap: CGFloat = 22
let barWidth = (barArea.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
for i in 0..<bars {
    let height = barArea.height * (0.28 + 0.72 * CGFloat(i + 1) / CGFloat(bars))
    let rect = CGRect(x: barArea.minX + CGFloat(i) * (barWidth + gap), y: barArea.maxY - height, width: barWidth, height: height)
    let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
    let on = i < 4
    ctx.saveGState()
    if on { ctx.setShadow(offset: .zero, blur: 30, color: rgb(phosphor, 0.8)) }
    ctx.addPath(path)
    ctx.setFillColor(rgb(phosphor, on ? 1 : 0.14))
    ctx.fillPath()
    ctx.restoreGState()
}

// Glass: a soft highlight across the top and a bright rim.
let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [rgb(0xFFFFFF, 0.2), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.minY + 360), options: [])
ctx.restoreGState()

ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
ctx.setLineWidth(4)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
