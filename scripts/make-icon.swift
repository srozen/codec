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

let phosphor: UInt32 = 0x52FFA8
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

// Phosphor bloom behind the C.
ctx.drawRadialGradient(gradient([(phosphor, 0.22, 0), (phosphor, 0, 1)]),
                       startCenter: CGPoint(x: 470, y: 512), startRadius: 0,
                       endCenter: CGPoint(x: 470, y: 512), endRadius: 420, options: [])

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

// The C: a stack of level bars cut to a ring that opens on the right, the top bar dimmed like a "max" line.
let pitch: CGFloat = 64, thickness: CGFloat = 44, outer: CGFloat = 300, inner: CGFloat = 150
glowing({
    for i in -4...4 {
        let offset = CGFloat(i) * pitch, d = abs(offset)
        let reach = sqrt(outer * outer - d * d)
        let right = d < inner ? -sqrt(inner * inner - d * d) : min(reach, (d - 60) * 1.15)
        ctx.setFillColor(color(phosphor, i == -4 ? 0.55 : 1))
        ctx.fill(CGRect(x: 512 - reach, y: 512 + offset - thickness / 2, width: right + reach, height: thickness))
    }
}, blur: 34)

// A block cursor waiting in the C's mouth.
glowing {
    ctx.addPath(CGPath(roundedRect: CGRect(x: 476, y: 448, width: 72, height: 128), cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(color(phosphor))
    ctx.fillPath()
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
