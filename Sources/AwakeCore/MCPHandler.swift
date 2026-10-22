import Foundation

/// A minimal MCP server (JSON-RPC 2.0, one message per line on stdio) that exposes Awake's
/// controls as tools. Transport lives in `awakectl`; this type only maps messages to replies.
public struct MCPHandler {
    public typealias Send = (ControlRequest) throws -> ControlResponse

    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public static let instructions = """
        Awake controls this Mac's keep-awake, lid-closed and hotspot settings. When the user says \
        they have to move or leave (for example "hey, I got to move", "heading out", "packing up"), call \
        awake_on_the_move with on=true before you reply. When they say they're settled or back at a \
        desk, call it with on=false. Report the result in one short sentence.
        """

    /// One week, matching the app's limit.
    static let maxMinutes = 10_080

    private let version: String
    private let send: Send

    public init(version: String, send: @escaping Send) {
        self.version = version
        self.send = send
    }

    /// The reply to one incoming message, or nil when none is due (notifications, client responses).
    public func reply(to message: [String: Any]) -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions[0]
            return result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "awake", "version": self.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": Self.tools])
        case "tools/call":
            return result(id, callTool(params))
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    private func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func callTool(_ params: [String: Any]) -> [String: Any] {
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let switches = ["awake_on_the_move", "awake_lid_closed_mode", "awake_auto_hotspot"]
        // JSON true/false only: a missing or malformed value must never turn something on.
        let on = (arguments["on"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
        if switches.contains(name), on == nil {
            return toolText("\"on\" must be true or false.", isError: true)
        }
        let request: ControlRequest
        switch name {
        case "awake_status":
            request = ControlRequest(.status)
        case "awake_on_the_move":
            request = ControlRequest(.move, on: on!)
        case "awake_keep_awake":
            switch arguments["mode"] as? String {
            case "off":
                request = ControlRequest(.keepAwake, on: false)
            case "while_claude_works":
                request = ControlRequest(.keepAwake, on: true, whileClaudeWorks: true)
            case "timed":
                guard let minutes = arguments["minutes"] as? Int, (1...Self.maxMinutes).contains(minutes) else {
                    return toolText("mode=timed needs minutes, a whole number from 1 to \(Self.maxMinutes).", isError: true)
                }
                request = ControlRequest(.keepAwake, on: true, minutes: minutes)
            default:
                request = ControlRequest(.keepAwake, on: true)
            }
        case "awake_lid_closed_mode":
            request = ControlRequest(.lidMode, on: on!)
        case "awake_auto_hotspot":
            request = ControlRequest(.autoHotspot, on: on!)
        case "awake_join_hotspot":
            request = ControlRequest(.joinHotspot)
        case let name:
            return toolText("Unknown tool: \(name)", isError: true)
        }

        do {
            let response = try send(request)
            var lines: [String] = []
            if let error = response.error { lines.append(error) }
            lines += response.notes ?? []
            if let summary = response.status?.summary { lines.append(summary) }
            if let status = response.status,
               let json = try? JSONEncoder.pretty.encode(status) {
                lines.append("\nDetails:\n" + String(decoding: json, as: UTF8.self))
            }
            return toolText(lines.joined(separator: "\n"), isError: !response.ok)
        } catch {
            return toolText("Couldn't reach the Awake app (\(error.localizedDescription)). Is Awake installed in /Applications?",
                            isError: true)
        }
    }

    private func toolText(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func tool(_ name: String, _ title: String, _ description: String,
                             _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "title": title, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    private static let onSwitch: [String: Any] = ["type": "boolean"]

    public static let tools: [[String: Any]] = [
        tool("awake_on_the_move", "On the Move", """
            Switch Awake's On the Move mode. Turn it ON whenever the user says they have to move, leave, \
            head out, pack up, commute, travel or go to a café while work keeps running, e.g. "hey, I got to \
            move", "I'm heading out", "gotta run", "packing up my laptop". It keeps the Mac running with the lid \
            closed and switches to the iPhone hotspot if the internet drops, so this and other Claude sessions \
            keep working. Turn it OFF when they say they're settled or back at a desk ("I'm back", "at my desk \
            now"); that restores their previous settings.
            """,
             ["on": ["type": "boolean", "description": "true = on the move, false = back at a desk"]], required: ["on"]),
        tool("awake_status", "Awake Status",
             "Show Awake's current state: On the Move, keep-awake, lid-closed mode, auto-hotspot, network (home or public, firewall shield), battery time left or charger, and whether the user's phone can reach this Mac (Tailscale + SSH)."),
        tool("awake_keep_awake", "Keep Awake",
             "Keep the Mac awake (lid open): indefinitely, for some minutes, or while Claude Code is working (it lets the Mac sleep a few minutes after every session goes idle). Or stop.",
             ["mode": ["type": "string", "enum": ["indefinitely", "timed", "while_claude_works", "off"]],
              "minutes": ["type": "integer", "minimum": 1, "maximum": maxMinutes, "description": "Only for mode=timed."]],
             required: ["mode"]),
        tool("awake_lid_closed_mode", "Lid-Closed Mode",
             "Turn lid-closed mode on or off (the Mac keeps running with the lid closed). The first time, macOS asks the user for their password.",
             ["on": onSwitch], required: ["on"]),
        tool("awake_auto_hotspot", "Auto-Hotspot",
             "Turn automatic switching to the iPhone hotspot (when the internet drops) on or off.",
             ["on": onSwitch], required: ["on"]),
        tool("awake_join_hotspot", "Join Hotspot", "Join the iPhone hotspot right now."),
    ]
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
