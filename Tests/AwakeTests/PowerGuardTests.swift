import XCTest
@testable import AwakeCore

final class HotBagGuardTests: XCTestCase {
    private func input(thermal: ThermalLevel = .nominal, lidClosed: Bool = true, externalDisplay: Bool = false,
                       onBattery: Bool = true, weakCharger: Bool = false, percent: Int? = 80,
                       keepingAwake: Bool = true, lidModeOn: Bool = true, lowPower: Bool = false,
                       enabled: Bool = true) -> GuardInput {
        GuardInput(thermal: thermal, lidClosed: lidClosed, externalDisplay: externalDisplay, onBattery: onBattery,
                   chargerTooWeak: weakCharger, batteryPercent: percent, keepingAwake: keepingAwake,
                   lidModeOn: lidModeOn, lowPowerOn: lowPower, enabled: enabled)
    }

    func testDisabledDoesNothingEvenWhenHotAndEmpty() {
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .critical, percent: 5, enabled: false)), .none)
    }

    func testNothingToProtectWhenNotKeepingAwakeAndLidModeOff() {
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .critical, percent: 5, keepingAwake: false, lidModeOn: false)), .none)
    }

    func testLowBatteryStopsAtTwentyPercent() {
        XCTAssertEqual(HotBagGuard.decide(input(percent: 20)), .stopAndSleep(.lowBattery(20)))
        XCTAssertEqual(HotBagGuard.decide(input(percent: 21)), .none)
    }

    func testLowBatteryAppliesWithLidOpenAndKeepAwakeOnly() {
        XCTAssertEqual(HotBagGuard.decide(input(lidClosed: false, percent: 10, lidModeOn: false)), .stopAndSleep(.lowBattery(10)))
    }

    func testLowBatteryIgnoredOnAC() {
        XCTAssertEqual(HotBagGuard.decide(input(onBattery: false, percent: 5)), .none)
    }

    func testUnknownBatteryPercentIsNotLow() {
        XCTAssertEqual(HotBagGuard.decide(input(percent: nil)), .none)
    }

    func testLowBatteryBeatsHot() {
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .critical, percent: 15)), .stopAndSleep(.lowBattery(15)))
    }

    func testSeriousAndCriticalHeatStopsWhenClosedInLidMode() {
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .serious)), .stopAndSleep(.hot))
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .critical, onBattery: false)), .stopAndSleep(.hot))
    }

    func testHeatIgnoredWithLidOpenOrLidModeOff() {
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .serious, lidClosed: false)), .none)
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .serious, lidModeOn: false)), .none)
    }

    func testFairHeatOnBatteryEnablesLowPower() {
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .fair)), .enableLowPower)
    }

    func testFairHeatNoLowPowerWhenAlreadyOnOrOnACOrNominal() {
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .fair, lowPower: true)), .none)
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .fair, onBattery: false)), .none)
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .nominal)), .none)
    }

    func testLowBatteryFiresOnAChargerTooWeakToKeepUp() {
        // A power bank or a weak charger reads as AC, but the battery still drains.
        XCTAssertEqual(HotBagGuard.decide(input(onBattery: false, weakCharger: true, percent: 15)),
                       .stopAndSleep(.lowBattery(15)))
        XCTAssertEqual(HotBagGuard.decide(input(onBattery: false, weakCharger: true, percent: 40)), .none)
        XCTAssertTrue(input(onBattery: false, weakCharger: true).discharging)
        XCTAssertFalse(input(onBattery: false, weakCharger: false).discharging)
    }

    func testWeakChargerDoesNotAskForBatteryLowPowerMode() {
        // `pmset -b lowpowermode` has no effect on AC, even a weak one.
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .fair, onBattery: false, weakCharger: true)), .none)
    }

    func testClamshellAtADeskIsNotABag() {
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .serious, externalDisplay: true)), .none)
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .critical, externalDisplay: true, onBattery: false)), .none)
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .fair, externalDisplay: true)), .none)
    }

    func testLowBatteryStillStopsAtADesk() {
        XCTAssertEqual(HotBagGuard.decide(input(externalDisplay: true, percent: 10)), .stopAndSleep(.lowBattery(10)))
    }

    func testSleepNowOnlyWithLidClosedAndNoExternalDisplay() {
        XCTAssertTrue(HotBagGuard.shouldSleepNow(lidClosed: true, externalDisplay: false))
        XCTAssertFalse(HotBagGuard.shouldSleepNow(lidClosed: true, externalDisplay: true), "clamshell at a desk")
        XCTAssertFalse(HotBagGuard.shouldSleepNow(lidClosed: false, externalDisplay: false))
    }

    func testThermalLevelOrderingAndMapping() {
        XCTAssertTrue(ThermalLevel.fair < .serious)
        XCTAssertEqual(ThermalLevel(.nominal), .nominal)
        XCTAssertEqual(ThermalLevel(.fair), .fair)
        XCTAssertEqual(ThermalLevel(.serious), .serious)
        XCTAssertEqual(ThermalLevel(.critical), .critical)
    }
}

final class GuardEpisodeTests: XCTestCase {
    func testStopsOncePerEpisode() {
        var episode = GuardEpisode()
        XCTAssertEqual(episode.filter(.stopAndSleep(.hot)), .stopAndSleep(.hot))
        // Lid-closed mode wouldn't turn off, so the guard still wants to stop: no second notification or sleep-now.
        XCTAssertEqual(episode.filter(.stopAndSleep(.hot)), .none)
        XCTAssertEqual(episode.filter(.stopAndSleep(.lowBattery(15))), .none)
    }

    func testANewEpisodeStartsOnceThereIsNothingToDo() {
        var episode = GuardEpisode()
        _ = episode.filter(.stopAndSleep(.hot))
        XCTAssertEqual(episode.filter(.none), .none)
        XCTAssertEqual(episode.filter(.stopAndSleep(.hot)), .stopAndSleep(.hot))
    }

    func testLowPowerPassesThroughAndKeepsTheEpisode() {
        var episode = GuardEpisode()
        XCTAssertEqual(episode.filter(.enableLowPower), .enableLowPower)
        _ = episode.filter(.stopAndSleep(.hot))
        XCTAssertEqual(episode.filter(.enableLowPower), .enableLowPower)
        XCTAssertEqual(episode.filter(.stopAndSleep(.hot)), .none)
    }
}

private final class FakeRunner: CommandRunning, @unchecked Sendable {
    var results: [String: CommandResult] = [:]
    private(set) var calls: [[String]] = []

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        calls.append([executable] + arguments)
        return results[executable] ?? CommandResult(status: 0, output: "")
    }
}

final class LowPowerModeControllerTests: XCTestCase {
    private func custom(battery: String, ac: String = " lowpowermode         0\n") -> String {
        """
        Battery Power:
         Sleep On Power Button 1
        \(battery) standby              1
         displaysleep         20
        AC Power:
         Sleep On Power Button 1
        \(ac) standby              1

        """
    }

    func testParsesBatterySectionNotAC() {
        let runner = FakeRunner()
        runner.results["/usr/bin/pmset"] = CommandResult(status: 0, output: custom(battery: " lowpowermode         1\n"))
        XCTAssertEqual(LowPowerModeController(runner: runner).isOnForBattery(), true)
        XCTAssertEqual(runner.calls, [["/usr/bin/pmset", "-g", "custom"]])
    }

    func testBatteryOffWhileACOn() {
        let runner = FakeRunner()
        runner.results["/usr/bin/pmset"] = CommandResult(status: 0, output: custom(battery: " lowpowermode         0\n", ac: " lowpowermode         1\n"))
        XCTAssertEqual(LowPowerModeController(runner: runner).isOnForBattery(), false)
    }

    func testMissingKeyIsNil() {
        let runner = FakeRunner()
        runner.results["/usr/bin/pmset"] = CommandResult(status: 0, output: custom(battery: "", ac: " lowpowermode         1\n"))
        XCTAssertNil(LowPowerModeController(runner: runner).isOnForBattery())
    }

    func testSetRunsExactSudoCommand() throws {
        let runner = FakeRunner()
        let controller = LowPowerModeController(runner: runner)
        try controller.setForBattery(true)
        try controller.setForBattery(false)
        XCTAssertEqual(runner.calls, [
            ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-b", "lowpowermode", "1"],
            ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-b", "lowpowermode", "0"],
        ])
        XCTAssertEqual(LowPowerModeController.command(true).last, "1")
    }

    func testSetThrowsWhenSudoFails() {
        let runner = FakeRunner()
        runner.results["/usr/bin/sudo"] = CommandResult(status: 1, output: "sudo: a password is required\n")
        XCTAssertThrowsError(try LowPowerModeController(runner: runner).setForBattery(true)) { error in
            XCTAssertEqual(error as? PrivilegedCommandError, .notPermitted("sudo: a password is required\n"))
        }
    }
}

final class SystemSleepTests: XCTestCase {
    func testPlainPmsetFirstAndNoSudoWhenItWorks() {
        let runner = FakeRunner()
        XCTAssertTrue(SystemSleep.sleepNow(runner: runner))
        XCTAssertEqual(runner.calls, [["/usr/bin/pmset", "sleepnow"]])
    }

    func testFallsBackToSudo() {
        let runner = FakeRunner()
        runner.results["/usr/bin/pmset"] = CommandResult(status: 1, output: "")
        XCTAssertTrue(SystemSleep.sleepNow(runner: runner))
        XCTAssertEqual(runner.calls, [["/usr/bin/pmset", "sleepnow"], ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "sleepnow"]])
    }

    func testReturnsFalseWhenBothFail() {
        let runner = FakeRunner()
        runner.results["/usr/bin/pmset"] = CommandResult(status: 1, output: "")
        runner.results["/usr/bin/sudo"] = CommandResult(status: 1, output: "")
        XCTAssertFalse(SystemSleep.sleepNow(runner: runner))
    }
}
