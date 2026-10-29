import XCTest
@testable import AwakeCore

private func sampleStatus(onTheMove: Bool = false) -> AwakeStatus {
    AwakeStatus(onTheMove: onTheMove, keepAwake: onTheMove, keepAwakeMinutesLeft: nil, lidClosedMode: onTheMove,
                  lidClosedModeSetUp: true, autoHotspot: onTheMove, hotspot: "Phone", hotspotReady: true,
                  online: true, wifi: "Home", onHotspot: false, batteryPercent: 80, onBattery: true,
                  summary: onTheMove ? "On the Move is on." : "The Mac sleeps normally.")
}

final class ControlSocketTests: XCTestCase {
    func testRoundTripOverTheSocket() throws {
        let path = "/tmp/awake-test-\(getpid()).sock"
        let server = ControlServer(path: path) { request in
            ControlResponse(ok: true, notes: ["got \(request.command.rawValue) \(request.on ?? false)"],
                            status: sampleStatus(onTheMove: request.on ?? false))
        }
        try server.start()
        defer { server.stop() }

        var mode = stat()
        XCTAssertEqual(stat(path, &mode), 0)
        XCTAssertEqual(mode.st_mode & 0o777, 0o600, "socket must be private to the user")

        let response = try ControlClient.send(ControlRequest(.move, on: true), path: path, timeout: 5)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.notes, ["got move true"])
        XCTAssertEqual(response.status?.onTheMove, true)
    }

    func testNewStatusFieldsRoundTripAndOldPayloadsStillDecode() throws {
        var status = sampleStatus()
        status.networkProfile = .public
        status.firewallShield = true
        status.batteryMinutesLeft = 190
        status.chargerTooWeak = false
        status.reachable = true
        status.reach = "Reachable · Tailscale + SSH"
        status.overnight = true
        status.overnightEnds = "at 9:00 AM"
        status.diskFreeGB = 41.3
        status.memoryPressure = "warning"
        status.cpuPercent = 12
        status.warnings = ["Memory is low, so apps and Claude slow down."]
        XCTAssertEqual(try JSONDecoder().decode(AwakeStatus.self, from: JSONEncoder().encode(status)), status)

        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sampleStatus())) as? [String: Any])
        for key in ["networkProfile", "firewallShield", "batteryMinutesLeft", "chargerWatts", "chargerTooWeak", "reachable", "reach",
                    "overnight", "overnightEnds", "diskFreeGB", "memoryPressure", "cpuPercent", "warnings"] {
            old.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(AwakeStatus.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.networkProfile)
        XCTAssertEqual(decoded.summary, "The Mac sleeps normally.")
    }

    func testASecondServerDoesNotTakeOverALiveSocket() throws {
        let path = "/tmp/awake-test-single-\(getpid()).sock"
        XCTAssertFalse(ControlClient.isServerRunning(path: path))
        let first = ControlServer(path: path) { _ in ControlResponse(ok: true, notes: ["first"]) }
        try first.start()
        defer { first.stop() }
        XCTAssertTrue(ControlClient.isServerRunning(path: path))

        let second = ControlServer(path: path) { _ in ControlResponse(ok: true, notes: ["second"]) }
        XCTAssertThrowsError(try second.start()) { error in
            guard case ControlSocketError.alreadyRunning = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try ControlClient.send(ControlRequest(.status), path: path, timeout: 5).notes, ["first"],
                       "the first copy still answers")
    }

    func testAStaleSocketFileIsReplaced() throws {
        let path = "/tmp/awake-test-stale-\(getpid()).sock"
        unlink(path)
        // A socket file nobody listens on, as a crash leaves it.
        let fd = try SocketIO.makeSocket()
        try SocketIO.withAddress(path) { address, length in XCTAssertEqual(Darwin.bind(fd, address, length), 0) }
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(ControlClient.isServerRunning(path: path))

        let next = ControlServer(path: path) { _ in ControlResponse(ok: true, notes: ["next"]) }
        try next.start()
        defer { next.stop() }
        XCTAssertEqual(try ControlClient.send(ControlRequest(.status), path: path, timeout: 5).notes, ["next"])
    }

    func testARequestWithoutOnDecodesWithNoValueSoTheAppCanRefuseIt() throws {
        let request = try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"command":"move"}"#.utf8))
        XCTAssertNil(request.on)
        XCTAssertNotNil(request.problem)
    }

    func testNothingListeningThrowsConnectError() {
        XCTAssertThrowsError(try ControlClient.send(ControlRequest(.status), path: "/tmp/awake-missing-\(getpid()).sock", timeout: 1)) { error in
            guard case ControlSocketError.system(let call, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(call, "connect")
        }
    }
}

final class ControlRequestTests: XCTestCase {
    func testSwitchesNeedAnExplicitOn() {
        for command in [ControlCommand.move, .lidMode, .autoHotspot, .keepAwake, .overnight] {
            XCTAssertNotNil(ControlRequest(command).problem, "\(command) without on must be refused, not read as on")
            XCTAssertNil(ControlRequest(command, on: true).problem)
            XCTAssertNil(ControlRequest(command, on: false).problem)
        }
    }

    func testCommandsWithoutASwitchNeedNothing() {
        XCTAssertNil(ControlRequest(.status).problem)
        XCTAssertNil(ControlRequest(.joinHotspot).problem)
    }

    func testKeepAwakeMinutesMustBeInRange() {
        XCTAssertNil(ControlRequest(.keepAwake, on: true, minutes: 1).problem)
        XCTAssertNil(ControlRequest(.keepAwake, on: true, minutes: ControlRequest.maxKeepAwakeMinutes).problem)
        XCTAssertNotNil(ControlRequest(.keepAwake, on: true, minutes: 0).problem)
        XCTAssertNotNil(ControlRequest(.keepAwake, on: true, minutes: ControlRequest.maxKeepAwakeMinutes + 1).problem)
        XCTAssertNil(ControlRequest(.keepAwake, on: false, minutes: 0).problem, "off ignores minutes")
    }

    func testEveryAwakectlRequestIsAccepted() {
        // What awakectl sends for each of its commands.
        let requests = [
            ControlRequest(.status), ControlRequest(.move, on: true), ControlRequest(.move, on: false),
            ControlRequest(.keepAwake, on: true, whileClaudeWorks: true), ControlRequest(.keepAwake, on: true),
            ControlRequest(.keepAwake, on: false), ControlRequest(.keepAwake, on: true, minutes: 90),
            ControlRequest(.lidMode, on: true), ControlRequest(.lidMode, on: false), ControlRequest(.joinHotspot),
            ControlRequest(.autoHotspot, on: true), ControlRequest(.autoHotspot, on: false),
            ControlRequest(.overnight, on: true), ControlRequest(.overnight, on: false),
            ControlRequest(.overnight, on: true, end: .whenClaudeFinishes), ControlRequest(.overnight, on: true, end: .manually),
        ]
        for request in requests {
            XCTAssertNil(request.problem, "\(request)")
        }
    }
}

final class MCPHandlerTests: XCTestCase {
    private var sent: [ControlRequest] = []

    private func handler(ok: Bool = true) -> MCPHandler {
        MCPHandler(version: "1.0.0") { request in
            self.sent.append(request)
            return ControlResponse(ok: ok, error: ok ? nil : "nope", status: sampleStatus(onTheMove: request.on ?? false))
        }
    }

    func testInitializeNegotiatesVersionAndGivesInstructions() throws {
        let reply = try XCTUnwrap(handler().reply(to: ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                       "params": ["protocolVersion": "2025-03-26"]]))
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertTrue((result["instructions"] as? String ?? "").contains("awake_on_the_move"))

        let unknown = try XCTUnwrap(handler().reply(to: ["jsonrpc": "2.0", "id": 2, "method": "initialize",
                                                        "params": ["protocolVersion": "1999-01-01"]]))
        XCTAssertEqual((unknown["result"] as? [String: Any])?["protocolVersion"] as? String, MCPHandler.supportedVersions[0])
    }

    func testNotificationsGetNoReply() {
        XCTAssertNil(handler().reply(to: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testToolsListIncludesOnTheMoveWithItsTriggers() throws {
        let reply = try XCTUnwrap(handler().reply(to: ["jsonrpc": "2.0", "id": "a", "method": "tools/list"]))
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let move = try XCTUnwrap(tools.first { $0["name"] as? String == "awake_on_the_move" })
        XCTAssertTrue((move["description"] as? String ?? "").contains("I got to"))
        XCTAssertEqual(reply["id"] as? String, "a")
        for tool in tools {
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        }
    }

    func testCallingOnTheMoveSendsMoveOn() throws {
        let reply = try XCTUnwrap(handler().reply(to: [
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "awake_on_the_move", "arguments": ["on": true]],
        ]))
        XCTAssertEqual(sent, [ControlRequest(.move, on: true)])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("On the Move is on."))
    }

    func testOvernightSendsItsEndOrLeavesItToSettings() throws {
        let call: ([String: Any]) -> [String: Any]? = { arguments in
            self.handler().reply(to: ["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                      "params": ["name": "awake_overnight", "arguments": arguments]])
        }
        _ = call(["on": true])
        _ = call(["on": true, "ends": "when_claude_finishes"])
        _ = call(["on": true, "ends": "when_turned_off"])
        _ = call(["on": true, "ends": "morning"])
        _ = call(["on": false])
        XCTAssertEqual(sent, [ControlRequest(.overnight, on: true), ControlRequest(.overnight, on: true, end: .whenClaudeFinishes),
                              ControlRequest(.overnight, on: true, end: .manually), ControlRequest(.overnight, on: true, end: .morning),
                              ControlRequest(.overnight, on: false)])
    }

    func testOvernightRefusesAnUnknownEndOrAMissingOn() throws {
        for arguments: [String: Any] in [["on": true, "ends": "tomorrow"], ["on": true, "ends": 9], ["ends": "morning"]] {
            let reply = try XCTUnwrap(handler().reply(to: [
                "jsonrpc": "2.0", "id": 10, "method": "tools/call",
                "params": ["name": "awake_overnight", "arguments": arguments],
            ]))
            XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true, "\(arguments)")
        }
        XCTAssertTrue(sent.isEmpty)
    }

    func testTimedKeepAwakeNeedsMinutes() throws {
        let reply = try XCTUnwrap(handler().reply(to: [
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "awake_keep_awake", "arguments": ["mode": "timed"]],
        ]))
        XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(sent.isEmpty)

        _ = handler().reply(to: [
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "awake_keep_awake", "arguments": ["mode": "timed", "minutes": 90]],
        ])
        XCTAssertEqual(sent, [ControlRequest(.keepAwake, on: true, minutes: 90)])
    }

    func testOnMustBeAJSONBoolean() throws {
        for bad: Any in ["false", 0, NSNull()] {
            let reply = try XCTUnwrap(handler().reply(to: [
                "jsonrpc": "2.0", "id": 8, "method": "tools/call",
                "params": ["name": "awake_on_the_move", "arguments": ["on": bad]],
            ]))
            XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
        XCTAssertTrue(sent.isEmpty, "nothing is switched on a malformed value")
        _ = handler().reply(to: ["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                 "params": ["name": "awake_on_the_move", "arguments": ["on": false]]])
        XCTAssertEqual(sent, [ControlRequest(.move, on: false)])
    }

    func testKeepAwakeNeedsAKnownMode() throws {
        for arguments: [String: Any] in [[:], ["mode": "forever"], ["mode": 1]] {
            let reply = try XCTUnwrap(handler().reply(to: [
                "jsonrpc": "2.0", "id": 11, "method": "tools/call",
                "params": ["name": "awake_keep_awake", "arguments": arguments],
            ]))
            XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true, "\(arguments)")
        }
        XCTAssertTrue(sent.isEmpty, "a missing or unknown mode must not keep the Mac awake")

        _ = handler().reply(to: ["jsonrpc": "2.0", "id": 12, "method": "tools/call",
                                 "params": ["name": "awake_keep_awake", "arguments": ["mode": "indefinitely"]]])
        _ = handler().reply(to: ["jsonrpc": "2.0", "id": 13, "method": "tools/call",
                                 "params": ["name": "awake_keep_awake", "arguments": ["mode": "while_claude_works"]]])
        _ = handler().reply(to: ["jsonrpc": "2.0", "id": 14, "method": "tools/call",
                                 "params": ["name": "awake_keep_awake", "arguments": ["mode": "off"]]])
        XCTAssertEqual(sent, [ControlRequest(.keepAwake, on: true),
                              ControlRequest(.keepAwake, on: true, whileClaudeWorks: true),
                              ControlRequest(.keepAwake, on: false)])
        XCTAssertTrue(sent.allSatisfy { $0.problem == nil }, "the app accepts everything the MCP server sends")
    }

    func testMissingOnIsRejectedForEverySwitch() throws {
        for name in ["awake_on_the_move", "awake_lid_closed_mode", "awake_auto_hotspot"] {
            let reply = try XCTUnwrap(handler().reply(to: [
                "jsonrpc": "2.0", "id": 15, "method": "tools/call", "params": ["name": name, "arguments": [:]],
            ]))
            XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true, name)
        }
        XCTAssertTrue(sent.isEmpty)
    }

    func testHugeMinutesAreRejected() throws {
        let reply = try XCTUnwrap(handler().reply(to: [
            "jsonrpc": "2.0", "id": 10, "method": "tools/call",
            "params": ["name": "awake_keep_awake", "arguments": ["mode": "timed", "minutes": Int.max]],
        ]))
        XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(sent.isEmpty)
    }

    func testFailedActionIsReportedAsToolError() throws {
        let reply = try XCTUnwrap(handler(ok: false).reply(to: [
            "jsonrpc": "2.0", "id": 6, "method": "tools/call",
            "params": ["name": "awake_join_hotspot", "arguments": [:]],
        ]))
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").hasPrefix("nope"))
    }

    func testALineThatIsNotJSONGetsAParseErrorWithIdNull() throws {
        let replies = handler().replies(toLine: "{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": ")
        XCTAssertEqual(replies.count, 1)
        let reply = try XCTUnwrap(replies.first)
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertTrue(reply["id"] is NSNull)
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
        XCTAssertTrue(wire.contains("\"id\":null"), wire)
        XCTAssertTrue(sent.isEmpty)
    }

    func testLinesThatAreNotMessagesAreRefusedAndBlankLinesIgnored() throws {
        XCTAssertTrue(handler().replies(toLine: "   ").isEmpty)
        let reply = try XCTUnwrap(handler().replies(toLine: "42").first)
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertTrue(reply["id"] is NSNull)
    }

    func testAValidLineAndABatchStillGetReplies() throws {
        let one = handler().replies(toLine: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        XCTAssertEqual(one.first?["id"] as? Int, 1)
        let batch = handler().replies(toLine: #"[{"jsonrpc":"2.0","id":2,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#)
        XCTAssertEqual(batch.count, 1, "the notification gets no reply")
        XCTAssertEqual(batch.first?["id"] as? Int, 2)
    }

    func testOnTheMoveToolSaysWhatElseItChangesAndThatItEnds() throws {
        let move = try XCTUnwrap(MCPHandler.tools.first { $0["name"] as? String == "awake_on_the_move" })
        let description = move["description"] as? String ?? ""
        for phrase in ["firewall", "Low Power Mode", "ends by itself"] {
            XCTAssertTrue(description.contains(phrase), phrase)
        }
    }

    func testUnknownMethodIsAnError() throws {
        let reply = try XCTUnwrap(handler().reply(to: ["jsonrpc": "2.0", "id": 7, "method": "resources/list"]))
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32601)
    }
}
