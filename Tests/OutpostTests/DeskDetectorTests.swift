import XCTest
@testable import OutpostCore

final class DeskDetectorTests: XCTestCase {
    private let desk = DeskState(externalDisplay: true, onPower: true)
    private let away = DeskState(externalDisplay: false, onPower: true)
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testAtDeskNeedsDisplayAndPower() {
        XCTAssertTrue(desk.atDesk)
        XCTAssertFalse(DeskState(externalDisplay: true, onPower: false).atDesk)
        XCTAssertFalse(DeskState(externalDisplay: false, onPower: true).atDesk)
    }

    func testFirstObservationIsSilent() {
        var detector = DeskDetector()
        XCTAssertNil(detector.update(desk, now: t0))
        XCTAssertNil(detector.update(desk, now: t0.addingTimeInterval(60)))
    }

    func testArrivedAfterHolding() {
        var detector = DeskDetector()
        _ = detector.update(away, now: t0)
        XCTAssertNil(detector.update(desk, now: t0.addingTimeInterval(1)))
        XCTAssertNil(detector.update(desk, now: t0.addingTimeInterval(3)))
        XCTAssertEqual(detector.update(desk, now: t0.addingTimeInterval(6)), .arrived)
        XCTAssertNil(detector.update(desk, now: t0.addingTimeInterval(20)))
    }

    func testLeftAfterHolding() {
        var detector = DeskDetector()
        _ = detector.update(desk, now: t0)
        XCTAssertNil(detector.update(away, now: t0.addingTimeInterval(1)))
        XCTAssertEqual(detector.update(away, now: t0.addingTimeInterval(7)), .left)
    }

    func testFlappingIsIgnored() {
        var detector = DeskDetector()
        _ = detector.update(away, now: t0)
        XCTAssertNil(detector.update(desk, now: t0.addingTimeInterval(1)))
        XCTAssertNil(detector.update(away, now: t0.addingTimeInterval(4)))
        XCTAssertNil(detector.update(desk, now: t0.addingTimeInterval(7)))
        XCTAssertNil(detector.update(desk, now: t0.addingTimeInterval(10)))
        XCTAssertEqual(detector.update(desk, now: t0.addingTimeInterval(12)), .arrived)
    }

    func testExactlyFiveSecondsCounts() {
        var detector = DeskDetector()
        _ = detector.update(away, now: t0)
        _ = detector.update(desk, now: t0.addingTimeInterval(1))
        XCTAssertEqual(detector.update(desk, now: t0.addingTimeInterval(6)), .arrived)
    }

    func testCanArriveAgainAfterLeaving() {
        var detector = DeskDetector()
        _ = detector.update(away, now: t0)
        _ = detector.update(desk, now: t0.addingTimeInterval(1))
        XCTAssertEqual(detector.update(desk, now: t0.addingTimeInterval(7)), .arrived)
        _ = detector.update(away, now: t0.addingTimeInterval(10))
        XCTAssertEqual(detector.update(away, now: t0.addingTimeInterval(16)), .left)
        _ = detector.update(desk, now: t0.addingTimeInterval(20))
        XCTAssertEqual(detector.update(desk, now: t0.addingTimeInterval(26)), .arrived)
    }
}
