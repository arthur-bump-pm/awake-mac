import Foundation

public struct FirewallState: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var stealth: Bool

    public init(enabled: Bool, stealth: Bool) {
        self.enabled = enabled
        self.stealth = stealth
    }
}

public enum FirewallError: Error, Equatable {
    case notPermitted(String)
}

/// Reads and changes the macOS application firewall. Changes go through `sudo -n`, so they need a sudoers rule for
/// exactly `--setglobalstate on|off` and `--setstealthmode on|off`; blocking all incoming connections is never touched.
public final class FirewallController {
    public static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    private let runner: CommandRunning

    public init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func read() -> FirewallState? {
        let global = runner.run(Self.tool, ["--getglobalstate"])
        let stealth = runner.run(Self.tool, ["--getstealthmode"])
        guard global.status == 0, stealth.status == 0,
              let enabled = Self.parseGlobalState(global.output),
              let stealthOn = Self.parseStealthMode(stealth.output) else { return nil }
        return FirewallState(enabled: enabled, stealth: stealthOn)
    }

    public func apply(_ target: FirewallState) throws {
        guard let current = read() else {
            throw FirewallError.notPermitted("Could not read the firewall state.")
        }
        for command in Self.commands(from: current, to: target) {
            let result = runner.run("/usr/bin/sudo", ["-n", Self.tool] + command)
            guard result.status == 0 else {
                throw FirewallError.notPermitted(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    /// Arguments for `socketfilterfw`. Stealth mode is turned off before the firewall goes off and on after it comes on.
    public static func commands(from: FirewallState, to: FirewallState) -> [[String]] {
        var result: [[String]] = []
        if from.stealth && !to.stealth { result.append(["--setstealthmode", "off"]) }
        if !from.enabled && to.enabled { result.append(["--setglobalstate", "on"]) }
        if !from.stealth && to.stealth { result.append(["--setstealthmode", "on"]) }
        if from.enabled && !to.enabled { result.append(["--setglobalstate", "off"]) }
        return result
    }

    static func parseGlobalState(_ output: String) -> Bool? {
        let text = output.lowercased()
        if text.contains("state = 0") || text.contains("is disabled") { return false }
        if text.contains("state = 1") || text.contains("state = 2") || text.contains("is enabled") { return true }
        return nil
    }

    static func parseStealthMode(_ output: String) -> Bool? {
        let text = output.lowercased()
        guard text.contains("stealth mode") else { return nil }
        if text.contains("is on") || text.contains("is enabled") { return true }
        if text.contains("is off") || text.contains("is disabled") { return false }
        return nil
    }
}
