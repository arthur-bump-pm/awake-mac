import Foundation

/// Messages between the Awake app and `awakectl` (CLI + MCP server), one JSON object per line
/// over a Unix socket that only the current user can open.
public enum ControlCommand: String, Codable, Sendable {
    case status, move, keepAwake, lidMode, autoHotspot, joinHotspot
}

public struct ControlRequest: Codable, Sendable, Equatable {
    public var command: ControlCommand
    public var on: Bool?
    /// keepAwake only: minutes for a timed session; nil with on=true means indefinitely.
    public var minutes: Int?
    /// keepAwake only: stay awake while any Claude Code session is working, then let the Mac sleep.
    public var whileClaudeWorks: Bool?

    public init(_ command: ControlCommand, on: Bool? = nil, minutes: Int? = nil, whileClaudeWorks: Bool? = nil) {
        self.command = command
        self.on = on
        self.minutes = minutes
        self.whileClaudeWorks = whileClaudeWorks
    }
}

public struct AwakeStatus: Codable, Sendable, Equatable {
    public var onTheMove: Bool
    public var keepAwake: Bool
    public var keepAwakeMinutesLeft: Int?
    public var lidClosedMode: Bool
    public var lidClosedModeSetUp: Bool
    public var autoHotspot: Bool
    public var hotspot: String?
    /// A hotspot is chosen and macOS lets Awake see Wi-Fi names.
    public var hotspotReady: Bool
    public var online: Bool?
    public var wifi: String?
    public var onHotspot: Bool
    public var batteryPercent: Int?
    public var onBattery: Bool
    public var keepAwakeWhileClaudeWorks: Bool
    /// Claude Code sessions working right now (each holds its own short keep-awake).
    public var claudeWorking: Int
    /// Other apps keeping the Mac awake, e.g. ["Google Chrome", "Insomnia"].
    public var otherAwakeApps: [String]
    public var captivePortal: Bool
    public var atDesk: Bool
    /// Home (a trusted Wi-Fi or the user's hotspot), public (any other Wi-Fi) or unknown (no Wi-Fi name).
    public var networkProfile: NetworkProfile?
    /// The firewall shield is on: up for On the Move or public Wi-Fi, and the firewall, as last read, has the firewall
    /// and stealth mode on.
    public var firewallShield: Bool?
    /// Estimated battery time left, on battery only.
    public var batteryMinutesLeft: Int?
    /// The plugged-in charger's rating.
    public var chargerWatts: Int?
    /// Plugged in, but the charger can't keep up and the battery is draining.
    public var chargerTooWeak: Bool?
    /// The owner's phone can reach this Mac now: Tailscale online and Remote Login on. `reach` says whether it lasts.
    public var reachable: Bool?
    /// One line about reach, e.g. "Reachable · Tailscale + SSH" or "Remote Login is off".
    public var reach: String?
    /// One or two plain sentences for people (and for Claude to relay).
    public var summary: String

    public init(onTheMove: Bool, keepAwake: Bool, keepAwakeMinutesLeft: Int?, lidClosedMode: Bool,
                lidClosedModeSetUp: Bool, autoHotspot: Bool, hotspot: String?, hotspotReady: Bool,
                online: Bool?, wifi: String?, onHotspot: Bool, batteryPercent: Int?, onBattery: Bool,
                keepAwakeWhileClaudeWorks: Bool = false, claudeWorking: Int = 0, otherAwakeApps: [String] = [],
                captivePortal: Bool = false, atDesk: Bool = false, networkProfile: NetworkProfile? = nil,
                firewallShield: Bool? = nil, batteryMinutesLeft: Int? = nil, chargerWatts: Int? = nil,
                chargerTooWeak: Bool? = nil, reachable: Bool? = nil, reach: String? = nil, summary: String) {
        self.onTheMove = onTheMove
        self.keepAwake = keepAwake
        self.keepAwakeMinutesLeft = keepAwakeMinutesLeft
        self.lidClosedMode = lidClosedMode
        self.lidClosedModeSetUp = lidClosedModeSetUp
        self.autoHotspot = autoHotspot
        self.hotspot = hotspot
        self.hotspotReady = hotspotReady
        self.online = online
        self.wifi = wifi
        self.onHotspot = onHotspot
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
        self.keepAwakeWhileClaudeWorks = keepAwakeWhileClaudeWorks
        self.claudeWorking = claudeWorking
        self.otherAwakeApps = otherAwakeApps
        self.captivePortal = captivePortal
        self.atDesk = atDesk
        self.networkProfile = networkProfile
        self.firewallShield = firewallShield
        self.batteryMinutesLeft = batteryMinutesLeft
        self.chargerWatts = chargerWatts
        self.chargerTooWeak = chargerTooWeak
        self.reachable = reachable
        self.reach = reach
        self.summary = summary
    }
}

public struct ControlResponse: Codable, Sendable {
    /// False when the requested action itself failed.
    public var ok: Bool
    public var error: String?
    /// Things the user should know even though the action went through (e.g. hotspot not chosen yet).
    public var notes: [String]?
    public var status: AwakeStatus?

    public init(ok: Bool, error: String? = nil, notes: [String]? = nil, status: AwakeStatus? = nil) {
        self.ok = ok
        self.error = error
        self.notes = notes
        self.status = status
    }
}

public enum ControlPaths {
    public static let bundleIdentifier = "io.github.arthur-bump-pm.Awake"

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Awake", isDirectory: true)
    }

    public static var socket: String {
        directory.appendingPathComponent("control.sock").path
    }
}
