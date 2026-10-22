// Renders Outpost's app icon (1024px PNG) and a menu bar glyph preview.
// Built together with Sources/Outpost/OutpostMark.swift by Scripts/make_icon.sh.
// Style: Dimension (Refero) — glossy void-black tile, soft white form, faint dusk-violet rim.
import AppKit

let outDir = CommandLine.arguments.dropFirst().first ?? "."
let violet = (r: 107, g: 98, b: 242)

func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func gray(_ v: Int, _ a: CGFloat = 1) -> CGColor { srgb(v, v, v, a) }

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func render(width: Int, height: Int, to name: String, _ draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx)
    let data = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}

/// macOS app-icon tile: a superellipse approximating Apple's continuous-corner squircle.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = CGPoint(x: rect.midX + a * copysign(pow(abs(c), 2 / n), c),
                        y: rect.midY + b * copysign(pow(abs(s), 2 / n), s))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func pill(_ r: CGRect) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
}

let edges: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

func drawIcon(_ ctx: CGContext, tile tileRect: CGRect) {
    let s = tileRect.width / 824
    let tile = squircle(tileRect)
    let top = CGPoint(x: tileRect.midX, y: tileRect.maxY)
    let bottom = CGPoint(x: tileRect.midX, y: tileRect.minY)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: gray(0, 0.38))
    ctx.addPath(tile)
    ctx.setFillColor(gray(10))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(gradient([gray(30), gray(16), gray(10), gray(7)], [0, 0.35, 0.7, 1]),
                           start: top, end: bottom, options: edges)

    // Violet rim: an inner glow from outside the tile, strongest at the bottom like dusk light.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.saveGState()
    let ring = CGMutablePath()
    ring.addRect(tileRect.insetBy(dx: -200 * s, dy: -200 * s))
    ring.addPath(tile)
    ctx.setShadow(offset: .zero, blur: 50 * s, color: srgb(violet.r, violet.g, violet.b))
    ctx.setFillColor(srgb(violet.r, violet.g, violet.b))
    for _ in 0..<2 {
        ctx.addPath(ring)
        ctx.fillPath(using: .evenOdd)
    }
    ctx.restoreGState()
    ctx.setBlendMode(.destinationIn)
    ctx.drawLinearGradient(gradient([gray(0, 0.18), gray(0, 0.5), gray(0, 0.8)], [0, 0.5, 1]),
                           start: top, end: bottom, options: edges)
    ctx.endTransparencyLayer()

    // Soft gloss at the top.
    ctx.saveGState()
    ctx.translateBy(x: tileRect.midX, y: tileRect.maxY - 60 * s)
    ctx.scaleBy(x: 1.6, y: 0.75)
    ctx.drawRadialGradient(gradient([gray(255, 0.085), gray(255, 0.03), gray(255, 0)], [0, 0.5, 1]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 330 * s, options: edges)
    ctx.restoreGState()

    // The eye: a glowing white pill with volume.
    let eye = OutpostMark.pillRect(in: tileRect)
    let eyePath = pill(eye)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 80 * s, color: gray(255, 0.18))
    ctx.addPath(eyePath)
    ctx.setFillColor(gray(240))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(eyePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([gray(255), gray(246), gray(214)], [0, 0.45, 1]),
                           start: CGPoint(x: eye.midX, y: eye.maxY), end: CGPoint(x: eye.midX, y: eye.minY), options: edges)
    ctx.setShadow(offset: CGSize(width: 0, height: 10 * s), blur: 18 * s, color: gray(120, 0.35))
    let outside = CGMutablePath()
    outside.addRect(eye.insetBy(dx: -60 * s, dy: -60 * s))
    outside.addPath(eyePath)
    ctx.addPath(outside)
    ctx.setFillColor(gray(0))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // Pupil, glancing forward, with a soft catchlight.
    let center = OutpostMark.pupilCenter(in: tileRect)
    let radius = OutpostMark.pupilRadius * tileRect.width
    ctx.saveGState()
    ctx.addEllipse(in: OutpostMark.circle(center, radius))
    ctx.clip()
    ctx.drawLinearGradient(gradient([gray(34), gray(10)], [0, 1]),
                           start: CGPoint(x: center.x, y: center.y + radius), end: CGPoint(x: center.x, y: center.y - radius), options: edges)
    ctx.restoreGState()
    let highlight = CGPoint(x: center.x - 0.36 * radius, y: center.y + 0.36 * radius)
    ctx.drawRadialGradient(gradient([gray(255, 0.9), gray(255, 0.75), gray(255, 0)], [0, 0.55, 1]),
                           startCenter: highlight, startRadius: 0, endCenter: highlight, endRadius: 0.22 * radius, options: [])
    ctx.restoreGState()

    // Dimension's hairline edge.
    ctx.addPath(squircle(tileRect.insetBy(dx: s, dy: s)))
    ctx.setStrokeColor(gray(255, 0.09))
    ctx.setLineWidth(2 * s)
    ctx.strokePath()
}

render(width: 1024, height: 1024, to: "icon_1024.png") { ctx in
    drawIcon(ctx, tile: CGRect(x: 100, y: 100, width: 824, height: 824))
}

// Menu bar glyph: asleep / awake / on the move, large and at true retina size, on light and dark bars.
render(width: 1020, height: 420, to: "glyph_preview.png") { ctx in
    let states: [OutpostMark.GlyphState] = [.asleep, .awake, .moving]
    for (row, dark) in [true, false].enumerated() {
        let y = CGFloat(row) * 210
        ctx.setFillColor(dark ? srgb(36, 36, 40) : srgb(236, 236, 238))
        ctx.fill(CGRect(x: 0, y: y, width: 1020, height: 210))
        for (i, state) in states.enumerated() {
            let x = 30 + CGFloat(i) * 330
            ctx.setFillColor(dark ? gray(255) : gray(0))
            ctx.setStrokeColor(dark ? gray(255) : gray(0))
            OutpostMark.drawGlyph(in: ctx, rect: CGRect(x: x, y: y + 25, width: 160, height: 160), state: state)
            OutpostMark.drawGlyph(in: ctx, rect: CGRect(x: x + 200, y: y + 87, width: 36, height: 36), state: state)
        }
    }
}
print("wrote icon_1024.png and glyph_preview.png to \(outDir)")
