import CoreGraphics
import Foundation

/// Awake's mark ("Mochi"): two soft marshmallow eyes with glossy pupils glancing up. The app icon draws
/// them as a glossy character (Scripts/IconRenderer) and the menu bar draws the same eyes as a template glyph
/// at any openness, so the status item can animate them opening and closing.
enum AwakeMark {
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

    /// The sleepy lid: a cubic centre line sagging downward from tip to tip, with tapered edges either side
    /// (thick in the middle, `tip` wide at the ends). Shared by `lidPath` and the opening eye.
    struct Lid {
        let p0: CGPoint, p3: CGPoint
        let tip: CGFloat
        let startAngle: CGFloat, endAngle: CGFloat
        /// The edges, left to right, one point per sample of the centre line.
        let lower: [CGPoint], upper: [CGPoint]

        init(center c: CGPoint, halfWidth hw: CGFloat, sag: CGFloat, thickness: CGFloat, tip: CGFloat) {
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
            let dEnd = tangent(1), dStart = tangent(0)
            self.p0 = p0
            self.p3 = p3
            self.tip = tip
            self.startAngle = atan2(dStart.dy, dStart.dx)
            self.endAngle = atan2(dEnd.dy, dEnd.dx)
            self.lower = lower
            self.upper = upper
        }
    }

    /// Closed eye: a sleepy lid drawn as a tapered stroke along a downward-sagging curve (thick in the
    /// middle, soft round tips), returned as one closed outline so fills and inner shadows stay clean.
    static func lidPath(center c: CGPoint, halfWidth hw: CGFloat, sag: CGFloat, thickness: CGFloat, tip: CGFloat) -> CGPath {
        let lid = Lid(center: c, halfWidth: hw, sag: sag, thickness: thickness, tip: tip)
        let path = CGMutablePath()
        path.move(to: lid.lower[0])
        for q in lid.lower.dropFirst() { path.addLine(to: q) }
        path.addArc(center: lid.p3, radius: tip / 2, startAngle: lid.endAngle - .pi / 2, endAngle: lid.endAngle + .pi / 2, clockwise: false)
        for q in lid.upper.reversed().dropFirst() { path.addLine(to: q) }
        path.addArc(center: lid.p0, radius: tip / 2, startAngle: lid.startAngle + .pi / 2, endAngle: lid.startAngle + 3 * .pi / 2, clockwise: false)
        path.closeSubpath()
        return path
    }

    /// An eye partway open (`openness` strictly between 0 and 1): the lid's outline morphed point for point into
    /// the open eye's. The lower edge becomes the eye's base, the upper edge lifts from the sagging lid line to
    /// the dome, and the lid's round tips close into the eye's sides; points are spread evenly along each part
    /// so the outline stays smooth all the way.
    static func openingEyePath(lid: Lid, eyeCenter c: CGPoint, width: CGFloat, height: CGFloat, n: CGFloat, flare: CGFloat,
                               openness m: CGFloat) -> CGPath {
        let a = width / 2 / (1 + flare * 0.45), b = height / 2
        func eye(from th0: CGFloat, to th1: CGFloat) -> [CGPoint] {   // the same superellipse as `eyePath`
            (0...240).map { i in
                let th = th0 + (th1 - th0) * CGFloat(i) / 240
                let co = cos(th), si = sin(th)
                let y = b * copysign(pow(abs(si), 2 / n), si)
                return CGPoint(x: c.x + a * copysign(pow(abs(co), 2 / n), co) * (1 - flare * y / b), y: c.y + y)
            }
        }
        func cap(_ center: CGPoint, from angle: CGFloat) -> [CGPoint] {
            (0...24).map { i in
                let th = angle + .pi * CGFloat(i) / 24
                return CGPoint(x: center.x + lid.tip / 2 * cos(th), y: center.y + lid.tip / 2 * sin(th))
            }
        }
        // Each lid tip becomes a short arc of the eye's side at the tip's height: centred on `tipAngle`, `side` either way.
        let tipAngle = asin(pow(min(max((lid.p3.y - c.y) / b, 0), 1), n / 2)), side: CGFloat = 0.1
        let parts: [(lid: [CGPoint], eye: [CGPoint], count: Int)] = [
            (lid.lower, eye(from: .pi - tipAngle + side, to: 2 * .pi + tipAngle - side), 121),
            (cap(lid.p3, from: lid.endAngle - .pi / 2), eye(from: tipAngle - side, to: tipAngle + side), 13),
            (lid.upper.reversed(), eye(from: tipAngle + side, to: .pi - tipAngle - side), 121),
            (cap(lid.p0, from: lid.startAngle + .pi / 2), eye(from: .pi - tipAngle - side, to: .pi - tipAngle + side), 13),
        ]
        let path = CGMutablePath()
        for part in parts {
            let from = resample(part.lid, count: part.count), to = resample(part.eye, count: part.count)
            for (p, q) in zip(from, to).dropLast() {         // each part's last point starts the next part
                let point = CGPoint(x: p.x + (q.x - p.x) * m, y: p.y + (q.y - p.y) * m)
                path.isEmpty ? path.move(to: point) : path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    /// `count` points spaced evenly along a polyline, both ends included.
    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        var lengths: [CGFloat] = [0]
        for (p, q) in zip(points, points.dropFirst()) { lengths.append(lengths.last! + hypot(q.x - p.x, q.y - p.y)) }
        let total = lengths.last!
        guard count > 1, total > 0 else { return Array(repeating: points[0], count: count) }
        var out: [CGPoint] = [], j = 0
        for i in 0..<count {
            let target = total * CGFloat(i) / CGFloat(count - 1)
            while j < points.count - 2 && lengths[j + 1] < target { j += 1 }
            let span = lengths[j + 1] - lengths[j]
            let f = span > 0 ? min(max((target - lengths[j]) / span, 0), 1) : 0
            out.append(CGPoint(x: points[j].x + (points[j + 1].x - points[j].x) * f,
                               y: points[j].y + (points[j + 1].y - points[j].y) * f))
        }
        return out
    }

    /// Menu bar template glyph in the context's current color, drawn as one layer so dimming doesn't show
    /// seams. Grid: 18 x 18 units. `openness` 0 is asleep (closed lids, dimmed), 1 is awake (open eyes looking
    /// up); in between the lids lift into the eyes, the pupils grow in and the ink goes from 55% to full.
    static func drawGlyph(in ctx: CGContext, rect: CGRect, openness: CGFloat) {
        let open = min(max(openness, 0), 1)
        let u = rect.width / 18
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
        ctx.saveGState()
        ctx.setAlpha(open < 1 ? 0.55 + 0.45 * open : 1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        // Asleep: the icon's sleepy lids, tapered: thick in the middle so they read as closed eyes, not letters.
        let lidY: CGFloat = 9.7
        func makeLid(_ cx: CGFloat) -> Lid { Lid(center: P(cx, lidY), halfWidth: 3.05 * u, sag: 2.2 * u, thickness: 2.3 * u, tip: 1.2 * u) }
        guard open > 0 else {
            for cx in [9 - 4.35, 9 + 4.35] as [CGFloat] {
                ctx.addPath(lidPath(center: P(cx, lidY), halfWidth: 3.05 * u, sag: 2.2 * u, thickness: 2.3 * u, tip: 1.2 * u))
            }
            ctx.fillPath()
            return
        }

        // Awake: open eyes (centred on the lids), pupils looking up, each with a catchlight.
        let ew: CGFloat = 6.7, eh: CGFloat = 8.6, gap: CGFloat = 2.0
        let rightX: CGFloat = 9 + (gap + ew) / 2
        let cy: CGFloat = 8.6, pr: CGFloat = 2.05
        func pupil(_ pc: CGPoint, scale s: CGFloat) {
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: circle(pc, pr * s * u))
            ctx.setBlendMode(.normal)
            ctx.fillEllipse(in: circle(CGPoint(x: pc.x - 0.62 * s * u, y: pc.y + 0.62 * s * u), 0.66 * s * u))
        }
        for x in [rightX - ew - gap, rightX] {
            let c = P(x, cy)
            ctx.setBlendMode(.normal)
            guard open < 1 else {
                ctx.addPath(eyePath(center: c, width: ew * u, height: eh * u, n: face.eyeN, flare: face.eyeFlare))
                ctx.fillPath()
                pupil(CGPoint(x: c.x, y: c.y + (eh / 2 - 0.9 - pr) * u), scale: 1)
                continue
            }
            let lid = makeLid(x)
            ctx.addPath(openingEyePath(lid: lid, eyeCenter: c, width: ew * u, height: eh * u, n: face.eyeN,
                                       flare: face.eyeFlare, openness: open))
            ctx.fillPath()
            // The pupils grow in once the eye has lifted a little, keeping their gap under the rising top.
            let grow = max(0, (open - 0.15) / 0.85)
            guard grow > 0 else { continue }
            let lidTop = lid.upper[lid.upper.count / 2].y   // the lid's upper edge at its middle
            let top = lidTop + (c.y + eh / 2 * u - lidTop) * open
            pupil(CGPoint(x: c.x, y: top - (0.9 + pr) * grow * u), scale: grow)
        }
    }
}
