import Combine
import XCTest
@testable import AwakeCore

final class MockRunner: CommandRunning, @unchecked Sendable {
    var sleepDisabled = false
    var sudoAllowed = true
    private(set) var calls: [[String]] = []

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        calls.append([executable] + arguments)
        switch executable {
        case "/usr/bin/pmset":
            return CommandResult(status: 0, output: " SleepDisabled\t\t\(sleepDisabled ? 1 : 0)\n hibernatemode 3\n")
        case "/usr/bin/sudo":
            guard sudoAllowed else { return CommandResult(status: 1, output: "sudo: a password is required\n") }
            sleepDisabled = arguments.last == "1"
            return CommandResult(status: 0, output: "")
        default:
            return CommandResult(status: 0, output: "")
        }
    }
}

@MainActor
final class LidModeControllerTests: XCTestCase {
    private func defaults(version: Int) -> UserDefaults {
        let suite = UserDefaults(suiteName: "awake-tests-\(UUID().uuidString)")!
        suite.set(version, forKey: "privilegedRuleVersion")
        return suite
    }

    func testReadsTheSystemSetting() {
        let runner = MockRunner()
        runner.sleepDisabled = true
        let controller = LidModeController(runner: runner, fileExists: { _ in true },
                                           defaults: defaults(version: LidModeController.ruleVersion))
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.isSetUp)
    }

    func testAnOlderRuleCountsAsNotSetUp() {
        let controller = LidModeController(runner: MockRunner(), fileExists: { _ in true }, defaults: defaults(version: 1))
        XCTAssertFalse(controller.isSetUp)
    }

    func testEnableRunsPmsetThroughSudoWithoutPrompting() async throws {
        let runner = MockRunner()
        let controller = LidModeController(runner: runner, fileExists: { _ in true })
        try await controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(runner.calls.contains(["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]))
    }

    func testRefusedSudoBeforeSetupAsksForSetup() async {
        let runner = MockRunner()
        runner.sudoAllowed = false
        let controller = LidModeController(runner: runner, fileExists: { _ in false })
        do {
            try await controller.setEnabled(true)
            XCTFail("expected needsSetUp")
        } catch {
            XCTAssertEqual(error as? LidModeError, .needsSetUp)
        }
        XCTAssertFalse(controller.isEnabled)
    }

    func testBlockingVariantsForQuitting() throws {
        let runner = MockRunner()
        let controller = LidModeController(runner: runner, fileExists: { _ in true })
        try controller.setEnabledNow(true)
        XCTAssertTrue(controller.isEnabled)
        runner.sleepDisabled = false
        controller.refreshNow()
        XCTAssertFalse(controller.isEnabled)
        runner.sudoAllowed = false
        XCTAssertThrowsError(try controller.setEnabledNow(true))
    }

    func testRefreshPicksUpAChangeMadeElsewhere() async {
        let runner = MockRunner()
        let controller = LidModeController(runner: runner, fileExists: { _ in true })
        XCTAssertFalse(controller.isEnabled)
        runner.sleepDisabled = true  // set by another tool or by hand
        await controller.refresh()
        XCTAssertTrue(controller.isEnabled)
    }

    func testAnUnchangedReadPublishesNothing() async {
        let runner = MockRunner()
        let controller = LidModeController(runner: runner, fileExists: { _ in true },
                                           defaults: defaults(version: LidModeController.ruleVersion))
        var changes = 0
        let watch = controller.objectWillChange.sink { changes += 1 }
        await controller.refresh()
        await controller.refresh()
        XCTAssertEqual(changes, 0, "a periodic read of the same state must not redraw the panel")
        runner.sleepDisabled = true
        await controller.refresh()
        XCTAssertEqual(changes, 1)
        watch.cancel()
    }

    func testParsesPmsetOutput() {
        XCTAssertTrue(LidModeController.sleepDisabled(inPmsetOutput: " SleepDisabled\t\t1\n"))
        XCTAssertFalse(LidModeController.sleepDisabled(inPmsetOutput: " SleepDisabled\t\t0\n"))
        XCTAssertFalse(LidModeController.sleepDisabled(inPmsetOutput: " sleep 1\n displaysleep 10\n"))
    }

    func testSudoersRuleAllowsOnlyTheListedCommands() throws {
        let rule = try XCTUnwrap(LidModeController.sudoersRule(for: "jane.doe"))
        XCTAssertTrue(rule.hasPrefix("jane.doe ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, "))
        XCTAssertTrue(rule.hasSuffix("--setstealthmode off\n"))
        XCTAssertFalse(rule.contains("*"), "no wildcards")
        XCTAssertFalse(rule.contains("setblockall"))
        XCTAssertEqual(rule.components(separatedBy: ", ").count, LidModeController.allowedCommands.count)
        XCTAssertNil(LidModeController.sudoersRule(for: "bad name"))
        XCTAssertNil(LidModeController.sudoersRule(for: "x' ; rm -rf /"))
        XCTAssertNil(LidModeController.sudoersRule(for: ""))
    }

    func testInstallScriptValidatesBeforeInstalling() throws {
        let script = LidModeController.installScript(rule: try XCTUnwrap(LidModeController.sudoersRule(for: "jane")))
        let validate = try XCTUnwrap(script.range(of: "visudo -cf"))
        let install = try XCTUnwrap(script.range(of: "mv -f"))
        XCTAssertLessThan(validate.lowerBound, install.lowerBound)
        XCTAssertTrue(script.hasPrefix("set -e"))
        XCTAssertTrue(script.contains(LidModeController.sudoersPath))
        XCTAssertTrue(script.hasSuffix("/bin/rm -f /etc/sudoers.d/outpost"), "the old Outpost rule is removed")
    }

    func testAppleScriptEscapesQuotesAndBackslashes() {
        let script = LidModeController.appleScript(runningAsAdmin: #"echo "a\b""#)
        XCTAssertTrue(script.hasPrefix(#"do shell script "echo \"a\\b\"""#))
        XCTAssertTrue(script.hasSuffix("with administrator privileges"))
    }
}
