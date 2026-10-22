import CoreGraphics
import Foundation

/// Outpost's mark: one wide white eye, looking ahead. The app icon draws it as a glossy pill
/// (Scripts/IconRenderer) and the menu bar draws the same pill as a template glyph.
enum OutpostMark {
    enum GlyphState {
        /// The Mac sleeps normally: the eye, dimmed.
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

    /// Menu bar template glyph in the context's current color: the app icon's pill eye, drawn as one
    /// layer so dimming doesn't show seams. Dimmed when asleep; shorter with motion lines when moving.
    static func drawGlyph(in ctx: CGContext, rect: CGRect, state: GlyphState) {
        let u = rect.width / 18
        ctx.saveGState()
        ctx.setAlpha(state == .asleep ? 0.45 : 1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        let height = 8 * u
        let moving = state == .moving
        let pill = CGRect(x: rect.minX + (moving ? 5.5 : 1) * u, y: rect.midY - height / 2,
                          width: (moving ? 11.5 : 16) * u, height: height)
        let eye = CGMutablePath()
        eye.addRoundedRect(in: pill, cornerWidth: height / 2, cornerHeight: height / 2)
        eye.addEllipse(in: circle(CGPoint(x: pill.minX + pill.width * 0.64, y: pill.midY), 1.75 * u))
        ctx.addPath(eye)
        ctx.fillPath(using: .evenOdd)

        guard moving else { return }
        let line = 1.5 * u
        for (x, y, width) in [(0.5, 1.6, 3.6), (1.7, -1.6, 2.4)] as [(CGFloat, CGFloat, CGFloat)] {
            let speed = CGRect(x: rect.minX + x * u, y: rect.midY + y * u - line / 2, width: width * u, height: line)
            ctx.addPath(CGPath(roundedRect: speed, cornerWidth: line / 2, cornerHeight: line / 2, transform: nil))
        }
        ctx.fillPath()
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
    }
}
