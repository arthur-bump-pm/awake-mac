import XCTest
import IOKit.pwr_mgt
@testable import AwakeCore

final class MockPowerAssertionManager: PowerAssertionManaging {
    private(set) var createdTypes: [String] = []
    private(set) var releaseCallCount = 0
    var shouldSucceed = true

    func create(type: CFString, name: CFString, id: inout IOPMAssertionID) -> IOReturn {
        createdTypes.append(type as String)
        id = 42
        return shouldSucceed ? kIOReturnSuccess : kIOReturnError
    }

    func release(id: IOPMAssertionID) {
        releaseCallCount += 1
    }
}

@MainActor
final class KeepAwakeControllerTests: XCTestCase {
    var mock: MockPowerAssertionManager!
    var controller: KeepAwakeController!

    override func setUp() {
        super.setUp()
        mock = MockPowerAssertionManager()
        controller = KeepAwakeController(assertionManager: mock)
    }

    override func tearDown() {
        controller.deactivate()
        controller = nil
        mock = nil
        super.tearDown()
    }

    func testStartsInactive() {
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.remainingTime)
    }

    func testIndefiniteSession() {
        controller.activate()
        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.activatedDuration)
        XCTAssertEqual(mock.createdTypes, [kIOPMAssertionTypeNoDisplaySleep as String])

        controller.deactivate()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(mock.releaseCallCount, 1)
    }

    func testTimedSession() {
        controller.activate(for: 60)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.remainingTime, 60)
        XCTAssertEqual(controller.activatedDuration, 60)
    }

    func testStartingAgainReplacesTheSession() {
        controller.activate(for: 60)
        controller.activate()
        XCTAssertEqual(mock.releaseCallCount, 1)
        XCTAssertNil(controller.activatedDuration)
    }

    func testDisplaySleepSwitchRebuildsAssertionAndKeepsTimer() {
        controller.activate(for: 600)
        controller.allowDisplaySleep = true
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.activatedDuration, 600)
        XCTAssertEqual(controller.remainingTime, 600)
        XCTAssertEqual(mock.createdTypes.last, kIOPMAssertionTypePreventUserIdleSystemSleep as String)
        XCTAssertEqual(mock.releaseCallCount, 1)
    }

    func testFailedAssertionLeavesItInactive() {
        mock.shouldSucceed = false
        controller.activate()
        XCTAssertFalse(controller.isActive)
    }
}
