import Foundation

/// Home or public: decides whether Awake shields this Mac on the current Wi-Fi.
public enum NetworkProfile: String, Codable, Sendable {
    /// A Wi-Fi the user trusts, or their own hotspot.
    case home
    /// Connected to a known Wi-Fi name the user hasn't trusted.
    case `public`
    /// No Wi-Fi, or no Location access so macOS hides the network's name.
    case unknown

    /// Which profile the current Wi-Fi gets. `hotspot` (the user's own) always counts as trusted.
    public static func decide(ssid: String?, trusted: [String], hotspot: String) -> NetworkProfile {
        guard let ssid, !ssid.isEmpty else { return .unknown }
        return ssid == hotspot || trusted.contains(ssid) ? .home : .public
    }
}

/// The profile the shield and shortcuts follow: the last definite one, held through short gaps without a Wi-Fi name
/// (waking, roaming) so the shield doesn't drop and come back. Not forever, though: leaving a café for Ethernet or
/// no Wi-Fi shouldn't keep the public shield up. It lapses to unknown after `maxHold` of unknown, or at once when
/// Wi-Fi is off. Pure; starts unknown.
public struct ProfileHold: Sendable {
    public static let maxHold: TimeInterval = 10 * 60

    public private(set) var profile: NetworkProfile = .unknown
    private var unknownSince: Date?

    public init() {}

    /// Feeds the profile decided from the current Wi-Fi name and returns the held one.
    @discardableResult
    public mutating func observe(_ decided: NetworkProfile, wifiOn: Bool, now: Date) -> NetworkProfile {
        if decided != .unknown || !wifiOn {
            profile = decided
            unknownSince = nil
            return profile
        }
        let since = unknownSince ?? now
        unknownSince = since
        if now.timeIntervalSince(since) >= Self.maxHold {
            profile = .unknown
        }
        return profile
    }
}

/// Runs a Shortcuts shortcut by name with the `shortcuts` tool.
public struct ShortcutRunner: Sendable {
    public static let tool = "/usr/bin/shortcuts"

    private let runner: CommandRunning
    /// For `list`: stdout only, so a warning on stderr can't show up as a shortcut's name.
    private let listRunner: CommandRunning

    /// A shortcut that waits for input would otherwise hang forever.
    public init(runner: CommandRunning = ProcessCommandRunner(timeout: 60),
                listRunner: CommandRunning = ProcessCommandRunner(timeout: 15, includesErrors: false)) {
        self.runner = runner
        self.listRunner = listRunner
    }

    /// Runs it and returns whether it finished without error. An empty name skips it (and counts as fine).
    @discardableResult
    public func run(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return true }
        return runner.run(Self.tool, ["run", name]).status == 0
    }

    /// The user's shortcuts by name (`shortcuts list`), sorted, for Settings to pick from; empty if the list fails.
    public func list() -> [String] {
        let result = listRunner.run(Self.tool, ["list"])
        guard result.status == 0 else { return [] }
        let names = result.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return Array(Set(names.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
