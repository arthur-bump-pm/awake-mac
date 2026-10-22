import CoreGraphics
import Foundation

/// Awake's mark ("Mochi"): two soft marshmallow eyes with glossy pupils glancing up. The app icon draws
/// them as a glossy character (Scripts/IconRenderer) and the menu bar draws the same eyes as a template glyph.
enum AwakeMark {
    enum GlyphState {
        /// The Mac sleeps normally: closed, sagging lids, dimmed.
        case asleep
        /// Something is keeping the Mac awake: open eyes, pupils looking up.
        case awake
        /// On the Move: leaning eyes glancing ahead, with speed lines behind them.
        case moving
    }

    /// The face as fractions of the tile width (shared with the icon renderer).
    struct Face {
        var eyeN: CGFloat = 3.0              // superellipse exponent: 2 = oval, 4+ = rounded square; 3 = marshmallow
        var eyeFlare: CGFloat = 0.12         // fuller at the bottom: a gumdrop, not an egg
        var eyeWidth: CGFloat = 0.235
        var eyeHeight: CGFloat = 0.27
        var eyeSpacing: CGFloat = 0.37       // centre to centre
        var eyeDrop: CGFloat = 0.045         // eyes sit a little below centre: a big forehead reads young
        var pupilRadius: CGFloat = 0.08
        var pupilTopGap: CGFloat = 0.017     // white left above the pupil: looking up
        var pupilInset: CGFloat = 0.012      // pupils drift toward the nose a hair
        var lidThickness: CGFloat = 0.06
        var lidSag: CGFloat = 0.052

        func eyeCenters(_ tile: CGRect) -> [CGPoint] {
            let w = tile.width
            let y = tile.midY - eyeDrop * w
            return [CGPoint(x: tile.midX - eyeSpacing / 2 * w, y: y), CGPoint(x: tile.midX + eyeSpacing / 2 * w, y: y)]
        }
    }

    static let face = Face()

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
    }

    /// A soft gumdrop: a superellipse (exponent `n`) that is a touch fuller at the bottom than the top.
    /// `width` is the widest point, so layouts can rely on it.
    static func eyePath(center c: CGPoint, width: CGFloat, height: CGFloat, n: CGFloat, flare: CGFloat, tilt: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        let a = width / 2 / (1 + flare * 0.45), b = height / 2
        let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: tilt)
        for i in 0...480 {
            let th = CGFloat(i) / 480 * 2 * .pi
            let co = cos(th), si = sin(th)
            let y = b * copysign(pow(abs(si), 2 / n), si)
            let x = a * copysign(pow(abs(co), 2 / n), co) * (1 - flare * y / b)
            i == 0 ? path.move(to: CGPoint(x: x, y: y), transform: t) : path.addLine(to: CGPoint(x: x, y: y), transform: t)
        }
        path.closeSubpath()
        return path
    }

    /// Closed eye: a sleepy lid drawn as a tapered stroke along a downward-sagging curve (thick in the
    /// middle, soft round tips), returned as one closed outline so fills and inner shadows stay clean.
    static func lidPath(center c: CGPoint, halfWidth hw: CGFloat, sag: CGFloat, thickness: CGFloat, tip: CGFloat) -> CGPath {
        let k: CGFloat = 4.0 / 3.0
        let p0 = CGPoint(x: c.x - hw, y: c.y), p3 = CGPoint(x: c.x + hw, y: c.y)
        let p1 = CGPoint(x: c.x - hw * 0.52, y: c.y - sag * k), p2 = CGPoint(x: c.x + hw * 0.52, y: c.y - sag * k)
        func at(_ t: CGFloat) -> CGPoint {
            let a = (1 - t) * (1 - t) * (1 - t), b = 3 * (1 - t) * (1 - t) * t, d = 3 * (1 - t) * t * t, e = t * t * t
            return CGPoint(x: a * p0.x + b * p1.x + d * p2.x + e * p3.x, y: a * p0.y + b * p1.y + d * p2.y + e * p3.y)
        }
        func tangent(_ t: CGFloat) -> CGVector {
            let a = 3 * (1 - t) * (1 - t), b = 6 * (1 - t) * t, d = 3 * t * t
            let v = CGVector(dx: a * (p1.x - p0.x) + b * (p2.x - p1.x) + d * (p3.x - p2.x),
                             dy: a * (p1.y - p0.y) + b * (p2.y - p1.y) + d * (p3.y - p2.y))
            let l = max(hypot(v.dx, v.dy), 1e-6)
            return CGVector(dx: v.dx / l, dy: v.dy / l)
        }
        func half(_ t: CGFloat) -> CGFloat { tip / 2 + (thickness - tip) / 2 * pow(sin(.pi * t), 0.8) }
        let n = 120
        var upper: [CGPoint] = [], lower: [CGPoint] = []
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let q = at(t), d = tangent(t), h = half(t)
            let nx = -d.dy, ny = d.dx            // left normal: "up" along a left-to-right curve
            upper.append(CGPoint(x: q.x + nx * h, y: q.y + ny * h))
            lower.append(CGPoint(x: q.x - nx * h, y: q.y - ny * h))
        }
        let path = CGMutablePath()
        path.move(to: lower[0])
        for q in lower.dropFirst() { path.addLine(to: q) }
        let dEnd = tangent(1), endAngle = atan2(dEnd.dy, dEnd.dx)
        path.addArc(center: p3, radius: tip / 2, startAngle: endAngle - .pi / 2, endAngle: endAngle + .pi / 2, clockwise: false)
        for q in upper.reversed().dropFirst() { path.addLine(to: q) }
        let dStart = tangent(0), startAngle = atan2(dStart.dy, dStart.dx)
        path.addArc(center: p0, radius: tip / 2, startAngle: startAngle + .pi / 2, endAngle: startAngle + 3 * .pi / 2, clockwise: false)
        path.closeSubpath()
        return path
    }

    /// Menu bar template glyph in the context's current color, drawn as one layer so dimming doesn't show
    /// seams. Grid: 18 x 18 units. Dimmed when asleep; leaning eyes with speed lines when moving.
    static func drawGlyph(in ctx: CGContext, rect: CGRect, state: GlyphState) {
        let u = rect.width / 18
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
        ctx.saveGState()
        ctx.setAlpha(state == .asleep ? 0.55 : 1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        switch state {
        case .awake, .moving:
            let moving = state == .moving
            let ew: CGFloat = moving ? 5.6 : 6.7
            let eh: CGFloat = moving ? 7.5 : 8.6
            let gap: CGFloat = moving ? 1.35 : 2.0
            let rightX: CGFloat = moving ? 18 - 0.45 - ew / 2 : 9 + (gap + ew) / 2
            let cy: CGFloat = moving ? 8.8 : 8.6
            let tilt: CGFloat = moving ? -0.13 : 0          // leaning into the direction of travel
            let pr: CGFloat = moving ? 1.85 : 2.05
            for x in [rightX - ew - gap, rightX] {
                let c = P(x, cy)
                ctx.setBlendMode(.normal)
                ctx.addPath(eyePath(center: c, width: ew * u, height: eh * u, n: face.eyeN, flare: face.eyeFlare, tilt: tilt))
                ctx.fillPath()
                var off = moving ? CGVector(dx: ew / 2 - 0.85 - pr, dy: 0.5) : CGVector(dx: 0, dy: eh / 2 - 0.9 - pr)
                off = CGVector(dx: off.dx * cos(tilt) - off.dy * sin(tilt), dy: off.dx * sin(tilt) + off.dy * cos(tilt))
                let pc = CGPoint(x: c.x + off.dx * u, y: c.y + off.dy * u)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: circle(pc, pr * u))
                ctx.setBlendMode(.normal)
                ctx.fillEllipse(in: circle(CGPoint(x: pc.x - 0.62 * u, y: pc.y + 0.62 * u), 0.66 * u))
            }
            guard moving else { return }
            let line = 1.15 * u
            for (x, y, len) in [(0.2, 10.9, 4.0), (1.7, 7.1, 2.5)] as [(CGFloat, CGFloat, CGFloat)] {
                let r = CGRect(x: rect.minX + x * u, y: rect.minY + y * u - line / 2, width: len * u, height: line)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: line / 2, cornerHeight: line / 2, transform: nil))
            }
            ctx.fillPath()
        case .asleep:
            // The icon's sleepy lids, tapered: thick in the middle so they read as closed eyes, not letters.
            for cx in [9 - 4.35, 9 + 4.35] as [CGFloat] {
                ctx.addPath(lidPath(center: P(cx, 9.7), halfWidth: 3.05 * u, sag: 2.2 * u, thickness: 2.3 * u, tip: 1.2 * u))
            }
            ctx.fillPath()
        }
    }
}
