import Foundation

/// The menu bar eyes opening or closing: openness over time (0 = closed lids, 1 = open eyes) and the frame
/// each openness snaps to. Pure; the app drives it from a main run loop timer and caches one image per step.
public struct EyeTransition: Equatable, Sendable {
    /// A full open: quick lift, soft landing (ease-out).
    public static let openDuration: TimeInterval = 0.35
    /// A full close: lids start gently and drop (ease-in), quadratic so the first frame changes within ~0.1 s.
    public static let closeDuration: TimeInterval = 0.3
    /// Timer interval while animating: up to 60 fps.
    public static let frameInterval: TimeInterval = 1.0 / 60
    /// Rendered frames: openness snaps to multiples of 1/steps, so 0 and 1 are exact and each frame is drawn once.
    public static let steps = 14

    public let from: Double
    public let to: Double
    public let start: TimeInterval
    /// Scaled by the distance left, so a transition that reverses mid-way takes only the time it needs.
    public let duration: TimeInterval

    /// A transition from wherever the eyes are now (mid-animation included). `reduceMotion` jumps straight
    /// to the end (System Settings → Accessibility → Display → Reduce motion).
    public init(from: Double, to: Double, start: TimeInterval, reduceMotion: Bool = false) {
        self.from = Self.clamp(from)
        self.to = Self.clamp(to)
        self.start = start
        let full = self.to > self.from ? Self.openDuration : Self.closeDuration
        duration = reduceMotion ? 0 : full * abs(self.to - self.from)
    }

    public var isOpening: Bool { to > from }

    public func openness(at time: TimeInterval) -> Double {
        let t = progress(at: time)
        guard t < 1 else { return to }
        return from + (to - from) * (isOpening ? Self.easeOut(t) : Self.easeIn(t))
    }

    public func isFinished(at time: TimeInterval) -> Bool {
        progress(at: time) >= 1
    }

    /// Linear time progress, 0...1; within a nanosecond of the end counts as the end (float noise in start + duration).
    private func progress(at time: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        let elapsed = time - start
        return elapsed >= duration - 1e-9 ? 1 : max(elapsed / duration, 0)
    }

    /// Cubic ease-out over 0...1 (input clamped).
    public static func easeOut(_ t: Double) -> Double {
        let t = clamp(t)
        return 1 - (1 - t) * (1 - t) * (1 - t)
    }

    /// Quadratic ease-in over 0...1 (input clamped).
    public static func easeIn(_ t: Double) -> Double {
        let t = clamp(t)
        return t * t
    }

    /// The frame for an openness: 0 (closed) ... `steps` (open).
    public static func step(for openness: Double) -> Int {
        Int((clamp(openness) * Double(steps)).rounded())
    }

    /// The openness a frame is drawn at.
    public static func openness(ofStep step: Int) -> Double {
        Double(min(max(step, 0), steps)) / Double(steps)
    }

    private static func clamp(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}
