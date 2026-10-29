// Renders Awake's app icon ("Awakie", awake state, 1024px PNG) and a menu bar glyph preview.
// Built together with Sources/Awake/AwakeMark.swift by Scripts/make_icon.sh.
// Style: Dimension (Refero) — glossy void-black tile, soft white eyes, faint dusk-violet rim.
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

let edges: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

/// Soft white volume: glow, top-lit gradient, an inner shadow that rounds the bottom edge, and
/// optionally the faint shade of an upper lid. `path` must be one simple closed outline.
func fillSoftWhite(_ ctx: CGContext, _ path: CGPath, s: CGFloat, glow: CGFloat = 0.17, lidShade: Bool = false) {
    let box = path.boundingBox
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70 * s, color: gray(255, glow))
    ctx.addPath(path)
    ctx.setFillColor(gray(240))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient([gray(255), gray(247), gray(212)], [0, 0.45, 1]),
                           start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: edges)
    let outside = CGMutablePath()
    outside.addRect(box.insetBy(dx: -80 * s, dy: -80 * s))
    outside.addPath(path)
    ctx.setShadow(offset: CGSize(width: 0, height: 9 * s), blur: 16 * s, color: gray(110, 0.34))
    ctx.addPath(outside)
    ctx.setFillColor(gray(0))
    ctx.fillPath(using: .evenOdd)
    if lidShade {
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 22 * s, color: gray(60, 0.30))
        ctx.addPath(outside)
        ctx.fillPath(using: .evenOdd)
    }
    ctx.restoreGState()
}

func drawPupil(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, clip eye: CGPath) {
    ctx.saveGState()
    ctx.addPath(eye)
    ctx.clip()
    ctx.addEllipse(in: AwakeMark.circle(c, r))
    ctx.clip()
    // A deep glossy bead: darkest at the top (under the lid), a whisper of bounce light at the bottom.
    ctx.drawLinearGradient(gradient([gray(4), gray(10), gray(30)], [0, 0.6, 1]),
                           start: CGPoint(x: c.x, y: c.y + r), end: CGPoint(x: c.x, y: c.y - r), options: edges)
    ctx.restoreGState()

    // Catchlights: one big soft sparkle up-left, one small one down-right.
    let big = CGPoint(x: c.x - 0.30 * r, y: c.y + 0.30 * r)
    ctx.drawRadialGradient(gradient([gray(255, 1), gray(255, 0.97), gray(255, 0)], [0, 0.8, 1]),
                           startCenter: big, startRadius: 0, endCenter: big, endRadius: 0.31 * r, options: [])
    let small = CGPoint(x: c.x + 0.40 * r, y: c.y - 0.36 * r)
    ctx.drawRadialGradient(gradient([gray(255, 0.92), gray(255, 0.85), gray(255, 0)], [0, 0.65, 1]),
                           startCenter: small, startRadius: 0, endCenter: small, endRadius: 0.13 * r, options: [])
}

func drawTile(_ ctx: CGContext, _ tileRect: CGRect) {
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

    // Soft gloss at the top: the dome of the forehead.
    ctx.saveGState()
    ctx.translateBy(x: tileRect.midX, y: tileRect.maxY - 60 * s)
    ctx.scaleBy(x: 1.6, y: 0.75)
    ctx.drawRadialGradient(gradient([gray(255, 0.085), gray(255, 0.03), gray(255, 0)], [0, 0.5, 1]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 330 * s, options: edges)
    ctx.restoreGState()
    ctx.restoreGState()
}

func drawHairline(_ ctx: CGContext, _ tileRect: CGRect) {
    let s = tileRect.width / 824
    ctx.addPath(squircle(tileRect.insetBy(dx: s, dy: s)))
    ctx.setStrokeColor(gray(255, 0.09))
    ctx.setLineWidth(2 * s)
    ctx.strokePath()
}

func drawIcon(_ ctx: CGContext, tile tileRect: CGRect) {
    let s = tileRect.width / 824
    let w = tileRect.width
    drawTile(ctx, tileRect)

    ctx.saveGState()
    ctx.addPath(squircle(tileRect))
    ctx.clip()

    let f = AwakeMark.face
    let ew = f.eyeWidth * w, eh = f.eyeHeight * w
    for (i, c) in f.eyeCenters(tileRect).enumerated() {
        let side: CGFloat = i == 0 ? -1 : 1
        let eye = AwakeMark.eyePath(center: c, width: ew, height: eh, n: f.eyeN, flare: f.eyeFlare)
        fillSoftWhite(ctx, eye, s: s, lidShade: true)
        let r = f.pupilRadius * w
        let pc = CGPoint(x: c.x - side * f.pupilInset * w, y: c.y + eh / 2 - f.pupilTopGap * w - r)
        drawPupil(ctx, center: pc, radius: r, clip: eye)
    }
    ctx.restoreGState()
    drawHairline(ctx, tileRect)
}

render(width: 1024, height: 1024, to: "icon_1024.png") { ctx in
    drawIcon(ctx, tile: CGRect(x: 100, y: 100, width: 824, height: 824))
}

// Menu bar glyph opening: openness 0 (asleep), 0.25, 0.5, 0.75, 1 (awake), large and at true retina size
// (18 pt = 36 px), on dark and light bars.
let openness: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
render(width: 1330, height: 420, to: "glyph_preview.png") { ctx in
    for (row, dark) in [true, false].enumerated() {
        let y = CGFloat(row) * 210
        ctx.setFillColor(dark ? srgb(36, 36, 40) : srgb(236, 236, 238))
        ctx.fill(CGRect(x: 0, y: y, width: 1330, height: 210))
        for (i, open) in openness.enumerated() {
            let x = 30 + CGFloat(i) * 260
            ctx.setFillColor(dark ? gray(255) : gray(0))
            AwakeMark.drawGlyph(in: ctx, rect: CGRect(x: x, y: y + 25, width: 160, height: 160), openness: open)
            AwakeMark.drawGlyph(in: ctx, rect: CGRect(x: x + 180, y: y + 87, width: 36, height: 36), openness: open)
        }
    }
}
print("wrote icon_1024.png and glyph_preview.png to \(outDir)")
