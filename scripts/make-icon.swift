// Renders Codec's app icon to a 1024×1024 PNG on the macOS icon grid.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Couldn't create a drawing context")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let ctx = graphics.cgContext

// Work top-down.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: stops.map(\.2))!
}

/// A continuous-curvature rounded square (superellipse), like the system icon shape.
func squircle(in rect: CGRect, exponent: CGFloat = 4.2) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / exponent), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / exponent), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

let phosphor: UInt32 = 0x5BFFAE
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(in: tile)

// Shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 26, color: color(0x000000, 0.45))
ctx.addPath(shape)
ctx.setFillColor(color(0x0B110E))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// Body: graphite with a green cast, lighter at the top.
ctx.drawLinearGradient(gradient([(0x1F2B25, 1, 0), (0x0E1612, 1, 0.5), (0x060A08, 1, 1)]),
                       start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])

// Phosphor bloom behind the prompt.
ctx.drawRadialGradient(gradient([(phosphor, 0.20, 0), (phosphor, 0, 1)]),
                       startCenter: CGPoint(x: 470, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 470, y: 560), endRadius: 400, options: [])

// Fine scanlines.
ctx.setFillColor(color(0x000000, 0.16))
var y = tile.minY + 2
while y < tile.maxY {
    ctx.fill(CGRect(x: tile.minX, y: y, width: tile.width, height: 3))
    y += 9
}

func glowing(_ draw: () -> Void, blur: CGFloat = 40) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: color(phosphor, 0.9))
    draw()
    ctx.restoreGState()
}

// The prompt: a chevron and a cursor.
let chevron = CGMutablePath()
chevron.move(to: CGPoint(x: 300, y: 382))
chevron.addLine(to: CGPoint(x: 476, y: 528))
chevron.addLine(to: CGPoint(x: 300, y: 674))
glowing {
    ctx.addPath(chevron)
    ctx.setStrokeColor(color(phosphor))
    ctx.setLineWidth(76)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}
glowing {
    ctx.addPath(CGPath(roundedRect: CGRect(x: 540, y: 634, width: 196, height: 76), cornerWidth: 38, cornerHeight: 38, transform: nil))
    ctx.setFillColor(color(phosphor))
    ctx.fillPath()
}

// Level meter, top right: the codec's thin rising bars, four of six lit.
let bars = 6
for i in 0..<bars {
    let height = 22 + CGFloat(i) * 14
    let rect = CGRect(x: 618 + CGFloat(i) * 24, y: 352 - height, width: 13, height: height)
    let bar = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
    if i < 4 {
        glowing({
            ctx.addPath(bar)
            ctx.setFillColor(color(phosphor, 0.95))
            ctx.fillPath()
        }, blur: 20)
    } else {
        ctx.addPath(bar)
        ctx.setFillColor(color(phosphor, 0.16))
        ctx.fillPath()
    }
}

// Glass: a soft sheen across the top and an inner vignette.
ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.16, 0), (0xFFFFFF, 0.0, 1)]),
                       start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.minY + 330), options: [])
ctx.drawRadialGradient(gradient([(0x000000, 0, 0.6), (0x000000, 0.35, 1)]),
                       startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 600, options: [])
ctx.restoreGState()

// Rim light.
ctx.addPath(squircle(in: tile.insetBy(dx: 2, dy: 2)))
ctx.setStrokeColor(color(0xFFFFFF, 0.2))
ctx.setLineWidth(3)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
do {
    try png.write(to: URL(fileURLWithPath: output))
} catch {
    fatalError("Couldn't write \(output): \(error)")
}
print("Wrote \(output)")
