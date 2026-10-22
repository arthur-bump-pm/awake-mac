import XCTest
@testable import AwakeCore

final class EyeTransitionTests: XCTestCase {
    func testEasingCurvesRunFromZeroToOne() {
        for ease in [EyeTransition.easeOut, EyeTransition.easeIn] {
            XCTAssertEqual(ease(0), 0)
            XCTAssertEqual(ease(1), 1)
            XCTAssertEqual(ease(-0.5), 0)
            XCTAssertEqual(ease(1.5), 1)
            var last = -1.0
            for i in 0...20 {
                let value = ease(Double(i) / 20)
                XCTAssertGreaterThanOrEqual(value, last)
                last = value
            }
        }
        // Ease-out is ahead of linear (fast start); ease-in is behind it (gentle start).
        XCTAssertEqual(EyeTransition.easeOut(0.5), 0.875, accuracy: 1e-9)
        XCTAssertEqual(EyeTransition.easeIn(0.5), 0.25, accuracy: 1e-9)
    }

    func testFullOpenTakesItsDurationAndEasesOut() {
        let open = EyeTransition(from: 0, to: 1, start: 100)
        XCTAssertTrue(open.isOpening)
        XCTAssertEqual(open.duration, EyeTransition.openDuration, accuracy: 1e-9)
        XCTAssertEqual(open.openness(at: 100), 0)
        XCTAssertEqual(open.openness(at: 99), 0)
        XCTAssertGreaterThan(open.openness(at: 100 + open.duration / 2), 0.5)
        XCTAssertFalse(open.isFinished(at: 100 + open.duration / 2))
        XCTAssertEqual(open.openness(at: 100 + open.duration), 1)
        XCTAssertEqual(open.openness(at: 200), 1)
        XCTAssertTrue(open.isFinished(at: 100 + open.duration))
    }

    func testFullCloseTakesItsDurationAndEasesIn() {
        let close = EyeTransition(from: 1, to: 0, start: 0)
        XCTAssertFalse(close.isOpening)
        XCTAssertEqual(close.duration, EyeTransition.closeDuration, accuracy: 1e-9)
        XCTAssertEqual(close.openness(at: 0), 1)
        XCTAssertGreaterThan(close.openness(at: close.duration / 2), 0.5)
        XCTAssertEqual(close.openness(at: close.duration), 0)
        // The first frame change (one step) comes within 0.1 s.
        let firstStep = 1 - 1 / Double(EyeTransition.steps) / 2
        XCTAssertLessThan(close.openness(at: 0.1), firstStep)
    }

    func testReversingMidwayContinuesFromTheCurrentOpennessInProportionalTime() {
        let open = EyeTransition(from: 0, to: 1, start: 0)
        let now = open.duration * 0.4
        let current = open.openness(at: now)
        let close = EyeTransition(from: current, to: 0, start: now)
        XCTAssertEqual(close.openness(at: now), current, accuracy: 1e-12)
        XCTAssertEqual(close.duration, EyeTransition.closeDuration * current, accuracy: 1e-9)
        XCTAssertEqual(close.openness(at: now + close.duration), 0)
    }

    func testReduceMotionAndNoDistanceJumpToTheEnd() {
        let reduced = EyeTransition(from: 0, to: 1, start: 5, reduceMotion: true)
        XCTAssertEqual(reduced.duration, 0)
        XCTAssertEqual(reduced.openness(at: 5), 1)
        XCTAssertTrue(reduced.isFinished(at: 5))

        let still = EyeTransition(from: 1, to: 1, start: 5)
        XCTAssertEqual(still.duration, 0)
        XCTAssertEqual(still.openness(at: 5), 1)
    }

    func testOpennessSnapsToCachedSteps() {
        let steps = EyeTransition.steps
        XCTAssertGreaterThanOrEqual(steps, 12)
        XCTAssertLessThanOrEqual(steps, 16)
        XCTAssertEqual(EyeTransition.step(for: 0), 0)
        XCTAssertEqual(EyeTransition.step(for: 1), steps)
        XCTAssertEqual(EyeTransition.step(for: -1), 0)
        XCTAssertEqual(EyeTransition.step(for: 2), steps)
        XCTAssertEqual(EyeTransition.step(for: .nan), 0)
        XCTAssertEqual(EyeTransition.step(for: 0.49 / Double(steps)), 0)
        XCTAssertEqual(EyeTransition.step(for: 0.51 / Double(steps)), 1)
        XCTAssertEqual(EyeTransition.openness(ofStep: 0), 0)
        XCTAssertEqual(EyeTransition.openness(ofStep: steps), 1)
        XCTAssertEqual(EyeTransition.openness(ofStep: steps + 3), 1)
        for step in 0...steps {
            XCTAssertEqual(EyeTransition.step(for: EyeTransition.openness(ofStep: step)), step)
        }
    }
}
