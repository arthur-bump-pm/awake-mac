import XCTest
@testable import AwakeCore

/// The shape of `tailscale status --json`, trimmed, with made-up names and addresses.
private let runningJSON = """
{
  "Version": "1.0.0-example",
  "TUN": false,
  "BackendState": "Running",
  "HaveNodeKey": true,
  "AuthURL": "",
  "TailscaleIPs": ["100.64.0.10", "fd7a:115c:a1e0::a"],
  "Self": {
    "ID": "nExample",
    "NodeID": 1,
    "HostName": "example-laptop",
    "DNSName": "example-laptop.example-tailnet.ts.net.",
    "OS": "macOS",
    "TailscaleIPs": ["100.64.0.10", "fd7a:115c:a1e0::a"],
    "Online": true,
    "Active": true
  },
  "Health": [],
  "MagicDNSSuffix": "example-tailnet.ts.net",
  "CurrentTailnet": {"Name": "example", "MagicDNSSuffix": "example-tailnet.ts.net", "MagicDNSEnabled": true},
  "ExtraRecords": null,
  "Peer": {},
  "User": {},
  "ClientVersion": null
}
"""

final class TailscaleStatusTests: XCTestCase {
    func testParsesOnlineSelfWithoutTheTrailingDot() throws {
        let status = try XCTUnwrap(TailscaleStatus.parse(runningJSON))
        XCTAssertTrue(status.online)
        XCTAssertEqual(status.dnsName, "example-laptop.example-tailnet.ts.net")
        XCTAssertEqual(status.ips, ["100.64.0.10", "fd7a:115c:a1e0::a"])
        XCTAssertEqual(status.sshHost, "example-laptop.example-tailnet.ts.net")
    }

    func testStoppedIsOffline() throws {
        let stopped = runningJSON.replacingOccurrences(of: "\"Running\"", with: "\"Stopped\"")
        XCTAssertFalse(try XCTUnwrap(TailscaleStatus.parse(stopped)).online)
        let selfOffline = runningJSON.replacingOccurrences(of: "\"Online\": true", with: "\"Online\": false")
        XCTAssertFalse(try XCTUnwrap(TailscaleStatus.parse(selfOffline)).online)
    }

    func testIgnoresAWarningBeforeTheJSON() throws {
        let output = "Warning: client version \"1.0.1\" != tailscaled server version \"1.0.0\"\n" + runningJSON
        XCTAssertTrue(try XCTUnwrap(TailscaleStatus.parse(output)).online)
    }

    func testWithoutMagicDNSUsesTheIPv4Address() throws {
        let noName = runningJSON.replacingOccurrences(of: "\"example-laptop.example-tailnet.ts.net.\"", with: "\"\"")
        let status = try XCTUnwrap(TailscaleStatus.parse(noName))
        XCTAssertNil(status.dnsName)
        XCTAssertEqual(status.sshHost, "100.64.0.10")
    }

    func testGarbageIsNil() {
        XCTAssertNil(TailscaleStatus.parse("failed to connect to local Tailscale service"))
        XCTAssertNil(TailscaleStatus.parse("{ not json }"))
    }
}

final class TailscaleCLITests: XCTestCase {
    private final class Runner: CommandRunning, @unchecked Sendable {
        var result = CommandResult(status: 0, output: runningJSON)
        private(set) var calls: [[String]] = []

        func run(_ executable: String, _ arguments: [String]) -> CommandResult {
            calls.append([executable] + arguments)
            return result
        }
    }

    func testNotInstalledRunsNothing() {
        let runner = Runner()
        XCTAssertNil(TailscaleCLI(runner: runner, locate: { nil }).status())
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testRunsStatusJSON() {
        let runner = Runner()
        let app = TailscaleCLI.paths[0]
        XCTAssertEqual(TailscaleCLI(runner: runner, locate: { app }).status()?.online, true)
        XCTAssertEqual(runner.calls, [[app, "status", "--json"]])
    }

    func testFindsHomebrewAndStandaloneInstallsToo() {
        XCTAssertEqual(TailscaleCLI.paths, ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                                            "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"])
        let runner = Runner()
        XCTAssertEqual(TailscaleCLI(runner: runner, locate: { "/opt/homebrew/bin/tailscale" }).status()?.online, true)
        XCTAssertEqual(runner.calls, [["/opt/homebrew/bin/tailscale", "status", "--json"]])
    }

    func testFailingCLIReadsAsOff() {
        let runner = Runner()
        runner.result = CommandResult(status: 1, output: "Tailscale is stopped.\n")
        XCTAssertEqual(TailscaleCLI(runner: runner, locate: { TailscaleCLI.paths[0] }).status(), .offline)
        runner.result = CommandResult(status: 0, output: "")
        XCTAssertEqual(TailscaleCLI(runner: runner, locate: { TailscaleCLI.paths[0] }).status(), .offline)
    }
}

final class RemoteReachTests: XCTestCase {
    private let online = TailscaleStatus(online: true, dnsName: "example-laptop.example-tailnet.ts.net",
                                         ips: ["100.64.0.10"])

    func testReachableWithEverythingOn() {
        let reach = RemoteReach.evaluate(tailscale: online, remoteLogin: true, lidClosedMode: true, user: "alex")
        XCTAssertEqual(reach, .reachable(ssh: "ssh alex@example-laptop.example-tailnet.ts.net"))
        XCTAssertEqual(reach.text, "Reachable · Tailscale + SSH")
        XCTAssertTrue(reach.isReachable)
    }

    func testFirstMissingPieceWins() {
        XCTAssertEqual(RemoteReach.evaluate(tailscale: nil, remoteLogin: false, lidClosedMode: false, user: "alex"),
                       .tailscaleMissing)
        XCTAssertEqual(RemoteReach.evaluate(tailscale: .offline, remoteLogin: false, lidClosedMode: false, user: "alex"),
                       .tailscaleOff)
        XCTAssertEqual(RemoteReach.evaluate(tailscale: online, remoteLogin: false, lidClosedMode: false, user: "alex"),
                       .remoteLoginOff)
        let sleepy = RemoteReach.evaluate(tailscale: online, remoteLogin: true, lidClosedMode: false, user: "alex")
        XCTAssertEqual(sleepy, .untilSleep(ssh: "ssh alex@example-laptop.example-tailnet.ts.net"))
        XCTAssertTrue(sleepy.isReachable)
    }

    func testKeepAwakeAloneIsOnlyUntilSleep() {
        // Keep-awake holds only while the lid is open; closing it sleeps the Mac. Only lid-closed mode lasts.
        let keepAwakeOnly = RemoteReach.evaluate(tailscale: online, remoteLogin: true, lidClosedMode: false, user: "alex")
        XCTAssertEqual(keepAwakeOnly.text, "Reachable until your Mac sleeps")
        XCTAssertEqual(keepAwakeOnly.sentence, "Your phone can reach this Mac over Tailscale + SSH until it sleeps.")
        let lidClosed = RemoteReach.evaluate(tailscale: online, remoteLogin: true, lidClosedMode: true, user: "alex")
        XCTAssertEqual(lidClosed.text, "Reachable · Tailscale + SSH")
    }

    func testOnlineWithoutAnAddressIsOff() {
        let empty = TailscaleStatus(online: true, dnsName: nil, ips: [])
        XCTAssertEqual(RemoteReach.evaluate(tailscale: empty, remoteLogin: true, lidClosedMode: true, user: "alex"),
                       .tailscaleOff)
    }

    func testTextAndSentences() {
        XCTAssertEqual(RemoteReach.tailscaleOff.text, "Tailscale is off")
        XCTAssertEqual(RemoteReach.remoteLoginOff.sentence, "Your phone can't reach this Mac: Remote Login is off.")
        XCTAssertNil(RemoteReach.remoteLoginOff.sshCommand)
    }
}
