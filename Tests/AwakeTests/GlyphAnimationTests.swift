import XCTest
@testable import AwakeCore

final class GlyphAnimationTests: XCTestCase {
    private let open = EyeTransition.openDuration, close = EyeTransition.closeDuration
    private let accentIn = GlyphAnimation.accentInDuration, accentOut = GlyphAnimation.accentOutDuration

    func testWakingIntoOvernightOpensTheEyesThenBringsInTheMoon() {
        let animation = GlyphAnimation(from: .asleep, open: true, accent: .moon, start: 10)
        XCTAssertEqual(animation.target, GlyphPose(openness: 1, accent: .moon, amount: 1))
        let midOpen = animation.pose(at: 10 + open / 2)
        XCTAssertGreaterThan(midOpen.openness, 0)
        XCTAssertLessThan(midOpen.openness, 1)
        XCTAssertEqual(midOpen.accent, .none, "the moon waits for the eyes")
        let midMoon = animation.pose(at: 10 + open + accentIn / 2)
        XCTAssertEqual(midMoon.openness, 1)
        XCTAssertEqual(midMoon.accent, .moon)
        XCTAssertGreaterThan(midMoon.amount, 0)
        XCTAssertLessThan(midMoon.amount, 1)
        XCTAssertFalse(animation.isFinished(at: 10 + open + accentIn - 0.01))
        XCTAssertTrue(animation.isFinished(at: 10 + open + accentIn))
        XCTAssertEqual(animation.pose(at: 99), animation.target)
    }

    func testKeepAwakeIsThePlainOpenEyes() {
        let animation = GlyphAnimation(from: .asleep, open: true, accent: .none, start: 0)
        XCTAssertEqual(animation.target, GlyphPose(openness: 1, accent: .none, amount: 0))
        XCTAssertTrue(animation.isFinished(at: open))
    }

    func testSwitchingModesTakesTheOldDetailOutBeforeTheNewComesIn() {
        let moon = GlyphPose(openness: 1, accent: .moon, amount: 1)
        let animation = GlyphAnimation(from: moon, open: true, accent: .speedLines, start: 0)
        let leaving = animation.pose(at: accentOut / 2)
        XCTAssertEqual(leaving.accent, .moon)
        XCTAssertLessThan(leaving.amount, 1)
        XCTAssertEqual(animation.pose(at: accentOut + 0.001).accent, .speedLines)
        XCTAssertEqual(animation.target, GlyphPose(openness: 1, accent: .speedLines, amount: 1))
        XCTAssertTrue(animation.isFinished(at: accentOut + accentIn))
    }

    func testTurningOffTakesTheDetailOutThenClosesTheEyes() {
        let moving = GlyphPose(openness: 1, accent: .speedLines, amount: 1)
        let animation = GlyphAnimation(from: moving, open: false, accent: .speedLines, start: 0)
        XCTAssertEqual(animation.pose(at: accentOut / 2).openness, 1, "the eyes stay open while the lines go")
        let closing = animation.pose(at: accentOut + close / 2)
        XCTAssertEqual(closing.accent, .none)
        XCTAssertLessThan(closing.openness, 1)
        XCTAssertEqual(animation.target, .asleep)
        XCTAssertTrue(animation.isFinished(at: accentOut + close))
    }

    func testAnInterruptedDetailContinuesFromWhereItWas() {
        let halfMoon = GlyphPose(openness: 1, accent: .moon, amount: 0.5)
        let animation = GlyphAnimation(from: halfMoon, open: true, accent: .moon, start: 0)
        XCTAssertEqual(animation.pose(at: 0).amount, 0.5, accuracy: 0.001)
        XCTAssertTrue(animation.isFinished(at: accentIn * 0.5), "only the half that's left")
    }

    func testReduceMotionJumpsToTheEnd() {
        let animation = GlyphAnimation(from: .asleep, open: true, accent: .moon, start: 0, reduceMotion: true)
        XCTAssertTrue(animation.isFinished(at: 0))
        XCTAssertEqual(animation.pose(at: 0), GlyphPose(openness: 1, accent: .moon, amount: 1))
    }

    func testFramesSnapAndDropAnEmptyDetail() {
        XCTAssertEqual(GlyphPose(openness: 1, accent: .moon, amount: 0).frame, GlyphFrame(eyeStep: EyeTransition.steps, accent: .none, accentStep: 0))
        XCTAssertEqual(GlyphPose(openness: 1, accent: .moon, amount: 0.5).frame.accentStep, GlyphFrame.accentSteps / 2)
        XCTAssertEqual(GlyphFrame(eyeStep: 3, accent: .none, accentStep: 5).accentStep, 0)
    }
}
