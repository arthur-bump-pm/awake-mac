import CoreGraphics
import Foundation

/// Outpost's mark: one wide white eye, looking ahead. The app icon draws it as a glossy pill
/// (Scripts/IconRenderer); the menu bar draws a lens-shaped eye that stays readable at 18 pt.
enum OutpostMark {
    enum GlyphState {
        /// The Mac sleeps normally: a closed eye.
        case asleep
        /// Something is keeping the Mac awake.
        case awake
        /// On the Move: the open eye with motion lines behind it.
        case moving
    }

    // App-icon proportions, as fractions of the tile width.
    static let pillWidth: CGFloat = 0.64
    static let pillHeight: CGFloat = 0.26
    static let pillLift: CGFloat = 0.014
    static let pupilRadius: CGFloat = 0.058
    /// Pupil centre as a fraction of the pill's width from its left end: glancing forward.
    static let pupilAt: CGFloat = 0.66

    static func pillRect(in tile: CGRect) -> CGRect {
        let width = pillWidth * tile.width, height = pillHeight * tile.width
        return CGRect(x: tile.midX - width / 2, y: tile.midY - height / 2 + pillLift * tile.width, width: width, height: height)
    }

    static func pupilCenter(in tile: CGRect) -> CGPoint {
        let pill = pillRect(in: tile)
        return CGPoint(x: pill.minX + pill.width * pupilAt, y: pill.midY)
    }

    /// Menu bar template glyph in the context's current color, drawn as one layer so dimming
    /// doesn't show seams where strokes overlap.
    static func drawGlyph(in ctx: CGContext, rect: CGRect, state: GlyphState) {
        let k = rect.width / 18
        ctx.saveGState()
        ctx.setAlpha(state == .asleep ? 0.55 : 1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let shift: CGFloat = state == .moving ? 2.2 * k : 0
        let eye = CGRect(x: rect.minX + 1.6 * k + shift, y: rect.midY - 3.1 * k, width: 14.8 * k - shift, height: 6.2 * k)

        guard state != .asleep else {
            let lid = CGMutablePath()
            lid.move(to: CGPoint(x: eye.minX, y: eye.midY + 0.6 * k))
            lid.addCurve(to: CGPoint(x: eye.maxX, y: eye.midY + 0.6 * k),
                         control1: CGPoint(x: eye.minX + eye.width * 0.3, y: eye.midY - 2.6 * k),
                         control2: CGPoint(x: eye.maxX - eye.width * 0.3, y: eye.midY - 2.6 * k))
            ctx.addPath(lid)
            ctx.setLineWidth(1.6 * k)
            ctx.strokePath()
            for (at, lean) in [(0.3, -0.6), (0.5, 0.0), (0.7, 0.6)] as [(CGFloat, CGFloat)] {
                let base = CGPoint(x: eye.minX + eye.width * at, y: eye.midY - 1.35 * k)
                ctx.move(to: base)
                ctx.addLine(to: CGPoint(x: base.x + lean * k, y: base.y - 2 * k))
            }
            ctx.setLineWidth(1.3 * k)
            ctx.strokePath()
            return
        }

        ctx.addPath(lens(eye))
        ctx.setLineWidth(1.55 * k)
        ctx.strokePath()
        ctx.fillEllipse(in: circle(CGPoint(x: eye.minX + eye.width * 0.6, y: eye.midY), 2.35 * k))

        if state == .moving {
            ctx.move(to: CGPoint(x: rect.minX + 0.7 * k, y: rect.midY + 1.5 * k))
            ctx.addLine(to: CGPoint(x: rect.minX + 2.4 * k, y: rect.midY + 1.5 * k))
            ctx.move(to: CGPoint(x: rect.minX + 0.7 * k, y: rect.midY - 1.5 * k))
            ctx.addLine(to: CGPoint(x: rect.minX + 2 * k, y: rect.midY - 1.5 * k))
            ctx.setLineWidth(1.4 * k)
            ctx.strokePath()
        }
    }

    /// An eye outline: two curves meeting at the corners.
    static func lens(_ r: CGRect) -> CGPath {
        let path = CGMutablePath()
        let left = CGPoint(x: r.minX, y: r.midY), right = CGPoint(x: r.maxX, y: r.midY)
        let bulge = r.height * 0.275
        path.move(to: left)
        path.addCurve(to: right, control1: CGPoint(x: r.minX + r.width * 0.28, y: r.maxY + bulge),
                      control2: CGPoint(x: r.maxX - r.width * 0.28, y: r.maxY + bulge))
        path.addCurve(to: left, control1: CGPoint(x: r.maxX - r.width * 0.28, y: r.minY - bulge),
                      control2: CGPoint(x: r.minX + r.width * 0.28, y: r.minY - bulge))
        path.closeSubpath()
        return path
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
    }
}
