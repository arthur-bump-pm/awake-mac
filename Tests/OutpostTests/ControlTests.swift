import XCTest
@testable import OutpostCore

private func sampleStatus(onTheMove: Bool = false) -> OutpostStatus {
    OutpostStatus(onTheMove: onTheMove, keepAwake: onTheMove, keepAwakeMinutesLeft: nil, lidClosedMode: onTheMove,
                  lidClosedModeSetUp: true, autoHotspot: onTheMove, hotspot: "Phone", hotspotReady: true,
                  online: true, wifi: "Home", onHotspot: false, batteryPercent: 80, onBattery: true,
                  summary: onTheMove ? "On the Move is on." : "The Mac sleeps normally.")
}

final class ControlSocketTests: XCTestCase {
    func testRoundTripOverTheSocket() throws {
        let path = "/tmp/outpost-test-\(getpid()).sock"
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

    func testNothingListeningThrowsConnectError() {
        XCTAssertThrowsError(try ControlClient.send(ControlRequest(.status), path: "/tmp/outpost-missing-\(getpid()).sock", timeout: 1)) { error in
            guard case ControlSocketError.system(let call, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(call, "connect")
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
        XCTAssertTrue((result["instructions"] as? String ?? "").contains("outpost_on_the_move"))

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
        let move = try XCTUnwrap(tools.first { $0["name"] as? String == "outpost_on_the_move" })
        XCTAssertTrue((move["description"] as? String ?? "").contains("I got to"))
        XCTAssertEqual(reply["id"] as? String, "a")
        for tool in tools {
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        }
    }

    func testCallingOnTheMoveSendsMoveOn() throws {
        let reply = try XCTUnwrap(handler().reply(to: [
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "outpost_on_the_move", "arguments": ["on": true]],
        ]))
        XCTAssertEqual(sent, [ControlRequest(.move, on: true)])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("On the Move is on."))
    }

    func testTimedKeepAwakeNeedsMinutes() throws {
        let reply = try XCTUnwrap(handler().reply(to: [
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "outpost_keep_awake", "arguments": ["mode": "timed"]],
        ]))
        XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(sent.isEmpty)

        _ = handler().reply(to: [
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "outpost_keep_awake", "arguments": ["mode": "timed", "minutes": 90]],
        ])
        XCTAssertEqual(sent, [ControlRequest(.keepAwake, on: true, minutes: 90)])
    }

    func testOnMustBeAJSONBoolean() throws {
        for bad: Any in ["false", 0, NSNull()] {
            let reply = try XCTUnwrap(handler().reply(to: [
                "jsonrpc": "2.0", "id": 8, "method": "tools/call",
                "params": ["name": "outpost_on_the_move", "arguments": ["on": bad]],
            ]))
            XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
        XCTAssertTrue(sent.isEmpty, "nothing is switched on a malformed value")
        _ = handler().reply(to: ["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                 "params": ["name": "outpost_on_the_move", "arguments": ["on": false]]])
        XCTAssertEqual(sent, [ControlRequest(.move, on: false)])
    }

    func testHugeMinutesAreRejected() throws {
        let reply = try XCTUnwrap(handler().reply(to: [
            "jsonrpc": "2.0", "id": 10, "method": "tools/call",
            "params": ["name": "outpost_keep_awake", "arguments": ["mode": "timed", "minutes": Int.max]],
        ]))
        XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(sent.isEmpty)
    }

    func testFailedActionIsReportedAsToolError() throws {
        let reply = try XCTUnwrap(handler(ok: false).reply(to: [
            "jsonrpc": "2.0", "id": 6, "method": "tools/call",
            "params": ["name": "outpost_join_hotspot", "arguments": [:]],
        ]))
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").hasPrefix("nope"))
    }

    func testUnknownMethodIsAnError() throws {
        let reply = try XCTUnwrap(handler().reply(to: ["jsonrpc": "2.0", "id": 7, "method": "resources/list"]))
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32601)
    }
}
