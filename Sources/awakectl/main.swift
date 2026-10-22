// awakectl: control the Awake app from a terminal, or serve it to Claude Code over MCP.
import Foundation
import AwakeCore

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

let usage = """
    usage: awakectl <command>

      status                    show what Awake is doing
      move on|off               On the Move mode (lid-closed + keep awake + auto-hotspot)
      awake on|off|claude|<minutes>
                                keep the Mac awake (lid open); "claude" = while Claude works
      lid on|off                lid-closed mode
      hotspot on|off|join       auto-hotspot, or join the hotspot now
      mcp                       run as an MCP server for Claude Code (stdio)

    Add to Claude Code:  claude mcp add --scope user awake -- "\(CommandLine.arguments[0])" mcp
    """

/// Sends a request, launching the app first if it isn't running.
func send(_ request: ControlRequest) throws -> ControlResponse {
    do {
        return try ControlClient.send(request)
    } catch let ControlSocketError.system(call, _) where call == "connect" {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", ControlPaths.bundleIdentifier]
        try open.run()
        open.waitUntilExit()
        var lastError: Error = ControlSocketError.badResponse
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            do {
                return try ControlClient.send(request)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

func runMCP() -> Never {
    let handler = MCPHandler(version: version, send: send)
    while let line = readLine(strippingNewline: true) {
        for reply in handler.replies(toLine: line) {
            guard var out = try? JSONSerialization.data(withJSONObject: reply) else { continue }
            out.append(0x0A)
            FileHandle.standardOutput.write(out)
        }
    }
    exit(0)
}

func onOff(_ word: String?) -> Bool? {
    switch word {
    case "on": true
    case "off": false
    default: nil
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let request: ControlRequest
switch (arguments.first, arguments.dropFirst().first) {
case ("mcp", _):
    runMCP()
case ("status", nil):
    request = ControlRequest(.status)
case ("move", let word?) where onOff(word) != nil:
    request = ControlRequest(.move, on: onOff(word))
case ("awake", "claude"):
    request = ControlRequest(.keepAwake, on: true, whileClaudeWorks: true)
case ("awake", let word?) where onOff(word) != nil:
    request = ControlRequest(.keepAwake, on: onOff(word))
case ("awake", let word?) where Int(word).map { (1...10_080).contains($0) } == true:
    request = ControlRequest(.keepAwake, on: true, minutes: Int(word))
case ("lid", let word?) where onOff(word) != nil:
    request = ControlRequest(.lidMode, on: onOff(word))
case ("hotspot", "join"):
    request = ControlRequest(.joinHotspot)
case ("hotspot", let word?) where onOff(word) != nil:
    request = ControlRequest(.autoHotspot, on: onOff(word))
default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

do {
    let response = try send(request)
    for line in [response.error].compactMap({ $0 }) + (response.notes ?? []) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    if let summary = response.status?.summary {
        print(summary)
    }
    exit(response.ok ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("awakectl: couldn't reach Awake: \(error.localizedDescription)\n".utf8))
    exit(1)
}
