import XCTest
@testable import AwakeCore

final class NetworkProfileTests: XCTestCase {
    func testTrustedNetworkIsHome() {
        XCTAssertEqual(NetworkProfile.decide(ssid: "Home Net", trusted: ["Office", "Home Net"], hotspot: "Phone"), .home)
    }

    func testOwnHotspotIsAlwaysHome() {
        XCTAssertEqual(NetworkProfile.decide(ssid: "Phone", trusted: [], hotspot: "Phone"), .home)
    }

    func testAnyOtherNamedWiFiIsPublic() {
        XCTAssertEqual(NetworkProfile.decide(ssid: "Cafe Guest", trusted: ["Home Net"], hotspot: "Phone"), .public)
        XCTAssertEqual(NetworkProfile.decide(ssid: "Cafe Guest", trusted: [], hotspot: ""), .public)
    }

    func testNoNameIsUnknown() {
        // No Wi-Fi, or no Location access so macOS hides the name.
        XCTAssertEqual(NetworkProfile.decide(ssid: nil, trusted: ["Home Net"], hotspot: "Phone"), .unknown)
        XCTAssertEqual(NetworkProfile.decide(ssid: "", trusted: [""], hotspot: ""), .unknown)
    }

    func testMatchingIsExact() {
        XCTAssertEqual(NetworkProfile.decide(ssid: "home net", trusted: ["Home Net"], hotspot: "Phone"), .public)
    }

    func testRawValuesForStatus() throws {
        let json = try JSONEncoder().encode([NetworkProfile.home, .public, .unknown])
        XCTAssertEqual(String(decoding: json, as: UTF8.self), #"["home","public","unknown"]"#)
    }
}

final class ProfileHoldTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    func testStartsUnknownAndFollowsDefiniteProfiles() {
        var hold = ProfileHold()
        XCTAssertEqual(hold.profile, .unknown)
        XCTAssertEqual(hold.observe(.public, wifiOn: true, now: start), .public)
        XCTAssertEqual(hold.observe(.home, wifiOn: true, now: start + 1), .home)
    }

    func testHoldsThroughAShortGapWithoutAName() {
        var hold = ProfileHold()
        hold.observe(.public, wifiOn: true, now: start)
        XCTAssertEqual(hold.observe(.unknown, wifiOn: true, now: start + 5), .public)
        XCTAssertEqual(hold.observe(.unknown, wifiOn: true, now: start + 5 + ProfileHold.maxHold - 1), .public)
        // The name is back: the gap is over and a later one starts its own clock.
        XCTAssertEqual(hold.observe(.public, wifiOn: true, now: start + 700), .public)
        XCTAssertEqual(hold.observe(.unknown, wifiOn: true, now: start + 800), .public)
        XCTAssertEqual(hold.observe(.unknown, wifiOn: true, now: start + 800 + ProfileHold.maxHold - 1), .public)
    }

    func testLapsesAfterTenMinutesOfUnknown() {
        // Leaving a café for Ethernet: Wi-Fi stays on but has no name.
        var hold = ProfileHold()
        hold.observe(.public, wifiOn: true, now: start)
        hold.observe(.unknown, wifiOn: true, now: start + 30)
        XCTAssertEqual(hold.observe(.unknown, wifiOn: true, now: start + 30 + ProfileHold.maxHold), .unknown)
        XCTAssertEqual(hold.observe(.unknown, wifiOn: true, now: start + 30 + 2 * ProfileHold.maxHold), .unknown)
    }

    func testWiFiOffLapsesAtOnce() {
        var hold = ProfileHold()
        hold.observe(.public, wifiOn: true, now: start)
        XCTAssertEqual(hold.observe(.unknown, wifiOn: false, now: start + 1), .unknown)
        XCTAssertEqual(hold.observe(.home, wifiOn: true, now: start + 2), .home)
    }
}

final class FirewallShieldTests: XCTestCase {
    private let off = FirewallState(enabled: false, stealth: false)

    func testWantedWhileEitherReasonHolds() {
        for onTheMove in [false, true] {
            for moveShield in [false, true] {
                for profile in [NetworkProfile.home, .public, .unknown] {
                    for publicShield in [false, true] {
                        let wanted = FirewallShield.isWanted(onTheMove: onTheMove, moveShield: moveShield,
                                                             profile: profile, publicShield: publicShield)
                        XCTAssertEqual(wanted, (onTheMove && moveShield) || (profile == .public && publicShield))
                    }
                }
            }
        }
    }

    func testOneSnapshotAcrossOverlappingReasons() {
        var shield = FirewallShield()
        func wanted(move: Bool, profile: NetworkProfile) -> Bool {
            FirewallShield.isWanted(onTheMove: move, moveShield: true, profile: profile, publicShield: true)
        }
        // On the Move starts at home: raise, snapshot the firewall as it was, and read it back shielded.
        XCTAssertEqual(shield.step(wanted: wanted(move: true, profile: .home)), .raise)
        shield.willRaise(from: off)
        shield.didApply(observed: FirewallShield.shielded)
        // Joining public Wi-Fi adds a reason: nothing to do, and the snapshot is untouched.
        XCTAssertEqual(shield.step(wanted: wanted(move: true, profile: .public)), .none)
        // On the Move ends, but public Wi-Fi still wants it.
        XCTAssertEqual(shield.step(wanted: wanted(move: false, profile: .public)), .none)
        XCTAssertEqual(shield.saved, off)
        // Back home: no reason left, lower to the original snapshot.
        XCTAssertEqual(shield.step(wanted: wanted(move: false, profile: .home)), .lower)
        XCTAssertEqual(shield.restoreTarget(current: FirewallShield.shielded), off)
        shield.didLower()
        XCTAssertFalse(shield.isUp)
        XCTAssertEqual(shield.step(wanted: false), .none)
    }

    func testRestoreTurnsOffOnlyWhatTheShieldTurnedOn() {
        var shield = FirewallShield()
        shield.willRaise(from: FirewallState(enabled: true, stealth: false))
        XCTAssertEqual(shield.restoreTarget(current: FirewallShield.shielded), FirewallState(enabled: true, stealth: false))
    }

    func testAlreadyShieldedRestoresNothing() {
        var shield = FirewallShield()
        shield.willRaise(from: FirewallShield.shielded)
        XCTAssertTrue(shield.isUp)
        XCTAssertEqual(shield.restoreTarget(current: FirewallShield.shielded), FirewallShield.shielded)
    }

    func testRestoreLeavesWhatTheUserChangedSince() {
        var shield = FirewallShield()
        shield.willRaise(from: FirewallState(enabled: true, stealth: false))
        // The user switched the firewall off themselves while shielded: don't switch it back on.
        XCTAssertEqual(shield.restoreTarget(current: FirewallState(enabled: false, stealth: true)), off)
    }

    func testSnapshotSurvivesARelaunch() throws {
        var shield = FirewallShield()
        shield.willRaise(from: off)
        let decoded = try JSONDecoder().decode(FirewallShield.self, from: JSONEncoder().encode(shield))
        XCTAssertEqual(decoded, shield)
        XCTAssertEqual(decoded.step(wanted: false), .lower)
    }

    func testAVerifiedRaiseIsDone() {
        var shield = FirewallShield()
        XCTAssertEqual(shield.step(wanted: true), .raise)
        shield.willRaise(from: off)
        XCTAssertEqual(shield.step(wanted: true), .reapply, "not read back yet")
        shield.didApply(observed: FirewallShield.shielded)
        XCTAssertTrue(shield.verified)
        XCTAssertEqual(shield.step(wanted: true), .none)
        XCTAssertEqual(shield.step(wanted: false), .lower)
    }

    func testFirstWantedStepAfterARelaunchReappliesAndKeepsTheSnapshot() throws {
        // A crash between the snapshot and the commands, or anything since: the snapshot alone proves nothing.
        var shield = FirewallShield()
        shield.willRaise(from: off)
        shield.didApply(observed: FirewallShield.shielded)
        var relaunched = try JSONDecoder().decode(FirewallShield.self, from: JSONEncoder().encode(shield))
        XCTAssertFalse(relaunched.verified)
        XCTAssertEqual(relaunched.step(wanted: true), .reapply)
        relaunched.didApply(observed: FirewallShield.shielded)
        XCTAssertEqual(relaunched.saved, off, "the snapshot is the firewall from before the first raise")
        XCTAssertEqual(relaunched.step(wanted: true), .none)
    }

    func testARaiseThatAppliedNothingDropsTheSnapshot() {
        var shield = FirewallShield()
        shield.willRaise(from: off)
        shield.didApply(observed: off)
        XCTAssertFalse(shield.isUp)
        XCTAssertEqual(shield.step(wanted: true), .raise, "tries again from a fresh snapshot")
        XCTAssertEqual(shield.step(wanted: false), .none)
    }

    func testAPartialRaiseKeepsTheSnapshotAndRetries() {
        let half = FirewallState(enabled: true, stealth: false)
        var shield = FirewallShield()
        shield.willRaise(from: off)
        shield.didApply(observed: half)
        XCTAssertEqual(shield.saved, off)
        XCTAssertEqual(shield.step(wanted: true), .reapply)
        // Not wanted any more: lowering turns off the half it did switch on.
        XCTAssertEqual(shield.step(wanted: false), .lower)
        XCTAssertEqual(shield.restoreTarget(current: half), off)
    }

    func testAnUnreadableFirewallAfterARaiseRetries() {
        var shield = FirewallShield()
        shield.willRaise(from: off)
        shield.didApply(observed: nil)
        XCTAssertEqual(shield.saved, off)
        XCTAssertEqual(shield.step(wanted: true), .reapply)
    }

    func testIsOnFollowsTheFirewallAsRead() {
        var shield = FirewallShield()
        XCTAssertFalse(shield.isOn(firewall: FirewallShield.shielded), "shielded by the user, not by the shield")
        shield.willRaise(from: off)
        shield.didApply(observed: FirewallShield.shielded)
        XCTAssertTrue(shield.isOn(firewall: FirewallShield.shielded))
        // The user switched the firewall off while shielded: it isn't on, and the shield doesn't fight them.
        XCTAssertFalse(shield.isOn(firewall: off))
        XCTAssertFalse(shield.isOn(firewall: FirewallState(enabled: true, stealth: false)))
        XCTAssertFalse(shield.isOn(firewall: nil))
        XCTAssertEqual(shield.step(wanted: true), .none)
    }

    func testAdoptsALegacySnapshotOnlyWhileDown() {
        var shield = FirewallShield()
        XCTAssertFalse(shield.adoptLegacy(nil))
        XCTAssertFalse(shield.isUp)
        // An older build shielded the firewall for On the Move and crashed: its snapshot becomes the shield's.
        XCTAssertTrue(shield.adoptLegacy(off))
        XCTAssertEqual(shield.saved, off)
        XCTAssertEqual(shield.step(wanted: true), .reapply)
        XCTAssertEqual(shield.step(wanted: false), .lower)
        XCTAssertEqual(shield.restoreTarget(current: FirewallShield.shielded), off)
        // Already up: the shield's own snapshot wins.
        XCTAssertFalse(shield.adoptLegacy(FirewallState(enabled: true, stealth: false)))
        XCTAssertEqual(shield.saved, off)
    }

    func testARaiseThatAppliedNothingIsNotLeftUp() throws {
        // apply() couldn't read the firewall (or sudo refused): nothing changed, so reading back drops the snapshot
        // instead of leaving a shield that says "up" over a firewall that is off.
        for failure in ["read", "sudo"] {
            let runner = ShieldRunner(off)
            let firewall = FirewallController(runner: runner)
            var shield = FirewallShield()
            shield.willRaise(from: try XCTUnwrap(firewall.read()))
            if failure == "read" { runner.failingReads = 1 } else { runner.sudoAllowed = 0 }
            XCTAssertThrowsError(try firewall.apply(FirewallShield.shielded))
            shield.didApply(observed: firewall.read())
            XCTAssertFalse(shield.isUp, failure)
            XCTAssertEqual(shield.step(wanted: true), .raise, failure)
        }
    }

    func testAPartialRaiseIsFinishedByTheRetry() throws {
        let runner = ShieldRunner(off)
        runner.sudoAllowed = 1  // the firewall comes on, stealth mode doesn't
        let firewall = FirewallController(runner: runner)
        var shield = FirewallShield()
        shield.willRaise(from: try XCTUnwrap(firewall.read()))
        XCTAssertThrowsError(try firewall.apply(FirewallShield.shielded))
        shield.didApply(observed: firewall.read())
        XCTAssertEqual(runner.state, FirewallState(enabled: true, stealth: false))
        XCTAssertEqual(shield.step(wanted: true), .reapply)

        runner.sudoAllowed = nil
        try firewall.apply(FirewallShield.shielded)
        shield.didApply(observed: firewall.read())
        XCTAssertEqual(shield.step(wanted: true), .none)
        XCTAssertEqual(shield.saved, off)
    }

    func testRaiseThenLowerThroughTheController() throws {
        let runner = ShieldRunner(off)
        let firewall = FirewallController(runner: runner)
        var shield = FirewallShield()
        shield.willRaise(from: try XCTUnwrap(firewall.read()))
        try firewall.apply(FirewallShield.shielded)
        try firewall.apply(shield.restoreTarget(current: try XCTUnwrap(firewall.read())))
        shield.didLower()
        XCTAssertEqual(runner.state, off)
        XCTAssertEqual(runner.sudoCalls.map { Array($0.suffix(2)) }, [
            ["--setglobalstate", "on"], ["--setstealthmode", "on"],
            ["--setstealthmode", "off"], ["--setglobalstate", "off"],
        ])
    }
}

private final class ShieldRunner: CommandRunning, @unchecked Sendable {
    var state: FirewallState
    /// How many more sudo calls succeed; nil = all of them.
    var sudoAllowed: Int?
    /// How many of the next firewall reads fail.
    var failingReads = 0
    private(set) var sudoCalls: [[String]] = []

    init(_ state: FirewallState) { self.state = state }

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        if executable == "/usr/bin/sudo" {
            if let allowed = sudoAllowed {
                guard allowed > 0 else { return CommandResult(status: 1, output: "sudo: a password is required\n") }
                sudoAllowed = allowed - 1
            }
            sudoCalls.append(arguments)
            let on = arguments.last == "on"
            if arguments.contains("--setglobalstate") { state.enabled = on }
            if arguments.contains("--setstealthmode") { state.stealth = on }
            return CommandResult(status: 0, output: "")
        }
        if arguments.first == "--getglobalstate" {
            guard failingReads == 0 else {
                failingReads -= 1
                return CommandResult(status: 1, output: "")
            }
            return CommandResult(status: 0, output: "Firewall is \(state.enabled ? "enabled. (State = 1)" : "disabled. (State = 0)")\n")
        }
        return CommandResult(status: 0, output: "Firewall stealth mode is \(state.stealth ? "on" : "off")\n")
    }
}

final class ShortcutRunnerTests: XCTestCase {
    private final class Runner: CommandRunning, @unchecked Sendable {
        var status: Int32 = 0
        var output = ""
        private(set) var calls: [[String]] = []

        func run(_ executable: String, _ arguments: [String]) -> CommandResult {
            calls.append([executable] + arguments)
            return CommandResult(status: status, output: output)
        }
    }

    func testListsShortcutsSortedWithoutBlanksOrRepeats() {
        let runner = Runner()
        runner.output = "Public Wi-Fi\n\nAt Home\nfocus 10\nfocus 2\nAt Home\n"
        XCTAssertEqual(ShortcutRunner(runner: runner, listRunner: runner).list(), ["At Home", "focus 2", "focus 10", "Public Wi-Fi"])
        XCTAssertEqual(runner.calls, [["/usr/bin/shortcuts", "list"]])
    }

    func testAFailedListIsEmpty() {
        let runner = Runner()
        runner.status = 1
        runner.output = "Error: not allowed"
        XCTAssertEqual(ShortcutRunner(runner: runner, listRunner: runner).list(), [])
    }

    func testRunsTheShortcutByName() {
        let runner = Runner()
        XCTAssertTrue(ShortcutRunner(runner: runner).run("  Cafe Mode "))
        XCTAssertEqual(runner.calls, [["/usr/bin/shortcuts", "run", "Cafe Mode"]])
    }

    func testEmptyNameIsSkipped() {
        let runner = Runner()
        XCTAssertTrue(ShortcutRunner(runner: runner).run("   "))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testFailureIsReported() {
        let runner = Runner()
        runner.status = 1
        XCTAssertFalse(ShortcutRunner(runner: runner).run("Missing"))
    }
}
