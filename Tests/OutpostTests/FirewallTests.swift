import XCTest
@testable import OutpostCore

private final class FirewallRunner: CommandRunning, @unchecked Sendable {
    var state: FirewallState
    var sudoAllowed = true
    var globalOutput: String?
    private(set) var calls: [[String]] = []

    init(_ state: FirewallState) { self.state = state }

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        calls.append([executable] + arguments)
        if executable == "/usr/bin/sudo" {
            guard sudoAllowed else { return CommandResult(status: 1, output: "sudo: a password is required\n") }
            let on = arguments.last == "on"
            if arguments.contains("--setglobalstate") { state.enabled = on }
            if arguments.contains("--setstealthmode") { state.stealth = on }
            return CommandResult(status: 0, output: "")
        }
        switch arguments.first {
        case "--getglobalstate":
            return CommandResult(status: 0, output: globalOutput ?? "Firewall is \(state.enabled ? "enabled. (State = 1)" : "disabled. (State = 0)")\n")
        default:
            return CommandResult(status: 0, output: "Firewall stealth mode is \(state.stealth ? "on" : "off")\n")
        }
    }

    var sudoCalls: [[String]] { calls.filter { $0.first == "/usr/bin/sudo" } }
}

final class FirewallTests: XCTestCase {
    private let all = [false, true].flatMap { e in [false, true].map { FirewallState(enabled: e, stealth: $0) } }

    func testCommandsAreEmptyWhenNothingChanges() {
        for state in all { XCTAssertEqual(FirewallController.commands(from: state, to: state), []) }
    }

    func testEnablingEverythingTurnsTheFirewallOnBeforeStealth() {
        XCTAssertEqual(
            FirewallController.commands(from: .init(enabled: false, stealth: false), to: .init(enabled: true, stealth: true)),
            [["--setglobalstate", "on"], ["--setstealthmode", "on"]])
    }

    func testDisablingEverythingTurnsStealthOffBeforeTheFirewall() {
        XCTAssertEqual(
            FirewallController.commands(from: .init(enabled: true, stealth: true), to: .init(enabled: false, stealth: false)),
            [["--setstealthmode", "off"], ["--setglobalstate", "off"]])
    }

    func testEveryPairRunsOnlyWhatDiffersAndNeverBlocksAll() {
        for from in all {
            for to in all {
                let commands = FirewallController.commands(from: from, to: to)
                let expected = (from.enabled != to.enabled ? 1 : 0) + (from.stealth != to.stealth ? 1 : 0)
                XCTAssertEqual(commands.count, expected)
                XCTAssertFalse(commands.contains { $0.contains("--setblockall") })
                let flat = commands.map { $0.joined(separator: " ") }
                if let on = flat.firstIndex(of: "--setglobalstate on"), let stealth = flat.firstIndex(of: "--setstealthmode on") {
                    XCTAssertLessThan(on, stealth)
                }
                if let off = flat.firstIndex(of: "--setglobalstate off"), let stealth = flat.firstIndex(of: "--setstealthmode off") {
                    XCTAssertLessThan(stealth, off)
                }
            }
        }
    }

    func testReadsRealOutputs() {
        let runner = FirewallRunner(.init(enabled: false, stealth: false))
        XCTAssertEqual(FirewallController(runner: runner).read(), .init(enabled: false, stealth: false))
        runner.state = .init(enabled: true, stealth: true)
        XCTAssertEqual(FirewallController(runner: runner).read(), .init(enabled: true, stealth: true))
    }

    func testParsesKnownWordings() {
        XCTAssertEqual(FirewallController.parseGlobalState("Firewall is disabled. (State = 0)\n"), false)
        XCTAssertEqual(FirewallController.parseGlobalState("Firewall is enabled. (State = 1)\n"), true)
        XCTAssertEqual(FirewallController.parseGlobalState("Firewall is blocking all non-essential incoming connections. (State = 2)\n"), true)
        XCTAssertEqual(FirewallController.parseStealthMode("Firewall stealth mode is off\n"), false)
        XCTAssertEqual(FirewallController.parseStealthMode("Firewall stealth mode is on\n"), true)
    }

    func testUnparseableOutputGivesNil() {
        let runner = FirewallRunner(.init(enabled: false, stealth: false))
        runner.globalOutput = "something unexpected"
        XCTAssertNil(FirewallController(runner: runner).read())
        XCTAssertNil(FirewallController.parseStealthMode("garbage"))
    }

    func testApplyRunsOnlyNeededCommandsThroughSudo() throws {
        let runner = FirewallRunner(.init(enabled: false, stealth: false))
        try FirewallController(runner: runner).apply(.init(enabled: true, stealth: true))
        XCTAssertEqual(runner.sudoCalls, [
            ["/usr/bin/sudo", "-n", FirewallController.tool, "--setglobalstate", "on"],
            ["/usr/bin/sudo", "-n", FirewallController.tool, "--setstealthmode", "on"],
        ])
        XCTAssertEqual(runner.state, .init(enabled: true, stealth: true))
    }

    func testApplyDoesNothingWhenAlreadyInTargetState() throws {
        let runner = FirewallRunner(.init(enabled: true, stealth: false))
        try FirewallController(runner: runner).apply(.init(enabled: true, stealth: false))
        XCTAssertTrue(runner.sudoCalls.isEmpty)
    }

    func testApplyThrowsWhenSudoRefuses() {
        let runner = FirewallRunner(.init(enabled: false, stealth: false))
        runner.sudoAllowed = false
        XCTAssertThrowsError(try FirewallController(runner: runner).apply(.init(enabled: true, stealth: false))) { error in
            XCTAssertEqual(error as? FirewallError, .notPermitted("sudo: a password is required"))
        }
    }
}
