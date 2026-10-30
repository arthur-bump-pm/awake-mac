import XCTest
import IOKit.pwr_mgt
@testable import AwakeCore

private final class ThreadSafeAssertionManager: PowerAssertionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _created = 0
    private var _released = 0
    var shouldSucceed = true

    var created: Int { lock.lock(); defer { lock.unlock() }; return _created }
    var released: Int { lock.lock(); defer { lock.unlock() }; return _released }

    func create(type: CFString, name: CFString, id: inout IOPMAssertionID) -> IOReturn {
        lock.lock(); defer { lock.unlock() }
        _created += 1
        id = 7
        return shouldSucceed ? kIOReturnSuccess : kIOReturnError
    }

    func release(id: IOPMAssertionID) {
        lock.lock(); defer { lock.unlock() }
        _released += 1
    }
}

final class AwakeWatchNameTests: XCTestCase {
    private func holder(_ pid: Int32, _ name: String) -> AwakeHolder {
        AwakeHolder(pid: pid, processName: name, assertionTypes: ["NoIdleSleepAssertion"], assertionNames: [])
    }

    func testGroupsCaffeinateUnderClaudeCodeWithCount() {
        let holders = [holder(10, "caffeinate"), holder(11, "caffeinate"), holder(12, "caffeinate")]
        let names = AwakeWatch.appNames(for: holders, parentOf: { $0 + 100 }, nameOf: { _ in "claude" })
        XCTAssertEqual(names, ["Claude Code (3)"])
    }

    func testCaffeinateWithOtherParentKeepsOwnName() {
        let names = AwakeWatch.appNames(for: [holder(10, "caffeinate")], parentOf: { _ in 1 }, nameOf: { _ in "zsh" })
        XCTAssertEqual(names, ["caffeinate"])
    }

    func testCaffeinateWithUnknownParentKeepsOwnName() {
        let names = AwakeWatch.appNames(for: [holder(10, "caffeinate")], parentOf: { _ in nil }, nameOf: { _ in nil })
        XCTAssertEqual(names, ["caffeinate"])
    }

    func testChromeHelpersCollapse() {
        let holders = [holder(1, "Google Chrome"), holder(2, "Google Chrome Helper (Renderer)")]
        let names = AwakeWatch.appNames(for: holders, parentOf: { _ in nil }, nameOf: { _ in nil })
        XCTAssertEqual(names, ["Google Chrome (2)"])
    }

    func testMixedListIsSorted() {
        let holders = [holder(1, "Insomnia"), holder(2, "caffeinate"), holder(3, "Google Chrome"), holder(4, "caffeinate")]
        let names = AwakeWatch.appNames(
            for: holders,
            parentOf: { _ in 9 },
            nameOf: { $0 == 9 ? "claude" : nil }
        )
        XCTAssertEqual(names, ["Claude Code (2)", "Google Chrome", "Insomnia"])
    }

    func testEmpty() {
        XCTAssertEqual(AwakeWatch.appNames(for: []), [])
    }

    func testLiveLookupsDoNotCrash() {
        _ = AwakeWatch.holders()
        _ = AgentScanner().scan()
        XCTAssertNotNil(AwakeWatch.processName(getpid()))
        XCTAssertNotNil(AwakeWatch.processParent(getpid()))
        XCTAssertNil(AwakeWatch.processName(Int32.max))
    }

    func testHoldersExcludesOwnPid() {
        XCTAssertFalse(AwakeWatch.holders(excluding: getpid()).contains { $0.pid == getpid() })
    }
}

final class ProcessAwakeHoldTests: XCTestCase {
    private func spawn(_ seconds: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        try process.run()
        return process
    }

    func testReleasesAndFiresOnExitWhenProcessEnds() throws {
        let child = try spawn("0.3")
        let mock = ThreadSafeAssertionManager()
        let exited = expectation(description: "onExit")
        let hold = try ProcessAwakeHold(pid: child.processIdentifier, reason: "test", assertionManager: mock) {
            exited.fulfill()
        }
        XCTAssertEqual(mock.created, 1)
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(mock.released, 1)
        hold.release()
        XCTAssertEqual(mock.released, 1)
    }

    func testReleaseIsIdempotentAndSuppressesOnExit() throws {
        let child = try spawn("5")
        defer { child.terminate() }
        let mock = ThreadSafeAssertionManager()
        let inverted = expectation(description: "onExit not called")
        inverted.isInverted = true
        let hold = try ProcessAwakeHold(pid: child.processIdentifier, reason: "test", assertionManager: mock) {
            inverted.fulfill()
        }
        hold.release()
        hold.release()
        XCTAssertEqual(mock.released, 1)
        child.terminate()
        child.waitUntilExit()
        wait(for: [inverted], timeout: 0.5)
        XCTAssertEqual(mock.released, 1)
    }

    func testDeinitReleases() throws {
        let child = try spawn("5")
        defer { child.terminate() }
        let mock = ThreadSafeAssertionManager()
        var hold: ProcessAwakeHold? = try ProcessAwakeHold(pid: child.processIdentifier, reason: "test", assertionManager: mock) {}
        XCTAssertNotNil(hold)
        hold = nil
        XCTAssertEqual(mock.released, 1)
    }

    func testThrowsWhenProcessNotRunning() {
        let mock = ThreadSafeAssertionManager()
        XCTAssertThrowsError(try ProcessAwakeHold(pid: Int32.max, reason: "test", assertionManager: mock) {}) {
            XCTAssertEqual($0 as? ProcessAwakeHold.HoldError, .processNotRunning)
        }
        XCTAssertEqual(mock.created, 0)
    }

    func testThrowsWhenAssertionFails() throws {
        let child = try spawn("5")
        defer { child.terminate() }
        let mock = ThreadSafeAssertionManager()
        mock.shouldSucceed = false
        XCTAssertThrowsError(try ProcessAwakeHold(pid: child.processIdentifier, reason: "test", assertionManager: mock) {}) {
            XCTAssertEqual($0 as? ProcessAwakeHold.HoldError, .assertionFailed)
        }
    }
}
