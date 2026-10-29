import Foundation

/// The small detail the menu bar glyph adds to the open eyes for a mode.
public enum GlyphAccent: Int, CaseIterable, Sendable {
    /// Keep awake (and lid-closed mode set elsewhere): the plain open eyes.
    case none
    /// Overnight: a crescent moon over Awakie's head.
    case moon
    /// On the Move: Awakie slides right, eyes glancing ahead, with speed lines behind.
    case speedLines
}

/// What the glyph shows: how open the eyes are, which detail, and how far the detail is in (0 = not at all, with the
/// eyes in their plain place; 1 = fully in).
public struct GlyphPose: Equatable, Sendable {
    public var openness: Double
    public var accent: GlyphAccent
    public var amount: Double

    public static let asleep = GlyphPose(openness: 0, accent: .none, amount: 0)

    public init(openness: Double, accent: GlyphAccent, amount: Double) {
        self.openness = openness
        self.accent = amount > 0 ? accent : .none
        self.amount = accent == .none ? 0 : amount
    }

    /// The cached frame this pose snaps to.
    public var frame: GlyphFrame {
        GlyphFrame(eyeStep: EyeTransition.step(for: openness), accent: accent,
                   accentStep: Int((min(max(amount, 0), 1) * Double(GlyphFrame.accentSteps)).rounded()))
    }
}

/// One rendered frame of the glyph; the app draws each once and caches it.
public struct GlyphFrame: Hashable, Sendable {
    public static let accentSteps = 12

    public let eyeStep: Int
    public let accent: GlyphAccent
    public let accentStep: Int

    public init(eyeStep: Int, accent: GlyphAccent, accentStep: Int) {
        self.eyeStep = eyeStep
        self.accent = accentStep > 0 ? accent : .none
        self.accentStep = accent == .none ? 0 : accentStep
    }

    public var openness: Double { EyeTransition.openness(ofStep: eyeStep) }
    public var amount: Double { Double(min(max(accentStep, 0), Self.accentSteps)) / Double(Self.accentSteps) }
}

/// The glyph moving to a new state, from wherever it is now (mid-animation included), in up to three phases: a detail
/// that's going away slides out first, then the eyes open or close (`EyeTransition`), then the new detail comes in
/// once the eyes are open. Nothing loops; Reduce Motion jumps to the end. Pure, like `EyeTransition`.
public struct GlyphAnimation: Sendable {
    public static let accentInDuration: TimeInterval = 0.6
    public static let accentOutDuration: TimeInterval = 0.25

    private enum Phase: Sendable {
        case accentOut(GlyphAccent, from: Double, start: TimeInterval, duration: TimeInterval)
        case eyes(EyeTransition)
        case accentIn(GlyphAccent, from: Double, start: TimeInterval, duration: TimeInterval)
    }

    public let start: GlyphPose
    public let target: GlyphPose
    private let phases: [Phase]
    private let end: TimeInterval

    /// `open`: anything keeps the Mac awake. `accent` is the mode's detail, shown only while open.
    public init(from pose: GlyphPose, open: Bool, accent: GlyphAccent, start time: TimeInterval, reduceMotion: Bool = false) {
        let wantOpen: Double = open ? 1 : 0
        let wantAccent = open ? accent : .none
        var current = pose
        var phases: [Phase] = []
        var t = time
        if current.amount > 0, current.accent != wantAccent {
            let duration = reduceMotion ? 0 : Self.accentOutDuration * current.amount
            phases.append(.accentOut(current.accent, from: current.amount, start: t, duration: duration))
            t += duration
            current = GlyphPose(openness: current.openness, accent: .none, amount: 0)
        }
        if current.openness != wantOpen {
            let eyes = EyeTransition(from: current.openness, to: wantOpen, start: t, reduceMotion: reduceMotion)
            phases.append(.eyes(eyes))
            t += eyes.duration
        }
        if wantAccent != .none, current.accent != wantAccent || current.amount < 1 {
            let from = current.accent == wantAccent ? current.amount : 0
            let duration = reduceMotion ? 0 : Self.accentInDuration * (1 - from)
            phases.append(.accentIn(wantAccent, from: from, start: t, duration: duration))
            t += duration
        }
        self.start = pose
        self.phases = phases
        self.end = t
        target = GlyphPose(openness: wantOpen, accent: wantAccent, amount: wantAccent == .none ? 0 : 1)
    }

    public func pose(at time: TimeInterval) -> GlyphPose {
        var pose = start
        for phase in phases {
            switch phase {
            case let .accentOut(accent, from, start, duration):
                guard time >= start else { return pose }
                let t = Self.progress(time, start, duration)
                pose = GlyphPose(openness: pose.openness, accent: accent, amount: from * (1 - EyeTransition.easeIn(t)))
                guard t >= 1 else { return pose }
            case let .eyes(eyes):
                guard time >= eyes.start else { return pose }
                pose = GlyphPose(openness: eyes.openness(at: time), accent: .none, amount: 0)
                guard eyes.isFinished(at: time) else { return pose }
            case let .accentIn(accent, from, start, duration):
                guard time >= start else { return pose }
                let t = Self.progress(time, start, duration)
                pose = GlyphPose(openness: pose.openness, accent: accent, amount: from + (1 - from) * EyeTransition.easeOut(t))
                guard t >= 1 else { return pose }
            }
        }
        return target
    }

    public func isFinished(at time: TimeInterval) -> Bool {
        time >= end - 1e-9
    }

    private static func progress(_ time: TimeInterval, _ start: TimeInterval, _ duration: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return min(max((time - start) / duration, 0), 1)
    }
}
