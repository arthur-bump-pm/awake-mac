import Foundation

/// What `tailscale status --json` says about this Mac.
public struct TailscaleStatus: Equatable, Sendable {
    /// Connected to the tailnet: the backend is running and this node is online.
    public var online: Bool
    /// The MagicDNS name, without the trailing dot.
    public var dnsName: String?
    public var ips: [String]

    public init(online: Bool, dnsName: String?, ips: [String]) {
        self.online = online
        self.dnsName = dnsName
        self.ips = ips
    }

    public static let offline = TailscaleStatus(online: false, dnsName: nil, ips: [])

    /// Where to ssh to: the MagicDNS name, else the first IPv4 address, else any address.
    public var sshHost: String? {
        dnsName ?? ips.first { !$0.contains(":") } ?? ips.first
    }

    /// Parses the CLI's JSON (reading `BackendState`, `Self.Online`, `Self.DNSName` and `TailscaleIPs`).
    /// Text around the JSON, like a version warning, is ignored. Nil when there's no JSON to read.
    public static func parse(_ output: String) -> TailscaleStatus? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(output[start...end].utf8)) else { return nil }
        let running = payload.backendState.map { $0 == "Running" } ?? true
        let name = payload.node?.dnsName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        return TailscaleStatus(online: running && payload.node?.online == true,
                               dnsName: name?.isEmpty == false ? name : nil,
                               ips: payload.node?.tailscaleIPs ?? payload.tailscaleIPs ?? [])
    }

    private struct Payload: Decodable {
        struct Node: Decodable {
            var online: Bool?
            var dnsName: String?
            var tailscaleIPs: [String]?

            enum CodingKeys: String, CodingKey {
                case online = "Online", dnsName = "DNSName", tailscaleIPs = "TailscaleIPs"
            }
        }

        var backendState: String?
        var node: Node?
        var tailscaleIPs: [String]?

        enum CodingKeys: String, CodingKey {
            case backendState = "BackendState", node = "Self", tailscaleIPs = "TailscaleIPs"
        }
    }
}

/// Reads this Mac's Tailscale status with its CLI: the one inside Tailscale.app (Mac App Store or standalone), or a
/// Homebrew or standalone `tailscale` on the usual paths. Blocks, so call it off the main actor.
public struct TailscaleCLI: Sendable {
    public static let appPath = "/Applications/Tailscale.app"
    /// Where the CLI can be, in order: inside the app, then Homebrew (Apple silicon, then Intel or a standalone CLI).
    public static let paths = [
        "\(appPath)/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    private let runner: CommandRunning
    private let locate: @Sendable () -> String?

    /// `locate` returns the CLI to run, or nil when Tailscale isn't installed.
    public init(runner: CommandRunning = ProcessCommandRunner(timeout: 5),
                locate: @escaping @Sendable () -> String? = {
                    TailscaleCLI.paths.first { FileManager.default.isExecutableFile(atPath: $0) }
                }) {
        self.runner = runner
        self.locate = locate
    }

    /// Nil when Tailscale isn't installed. Stopped, logged out or not answering all read as offline.
    public func status() -> TailscaleStatus? {
        guard let path = locate() else { return nil }
        let result = runner.run(path, ["status", "--json"])
        guard result.status == 0 else { return .offline }
        return TailscaleStatus.parse(result.output) ?? .offline
    }
}

/// Whether the owner's phone can reach this Mac while they're away: Tailscale online, Remote Login (SSH) on, and
/// lid-closed mode on.
public enum RemoteReach: Equatable, Sendable {
    case reachable(ssh: String)
    /// Reachable now, but the Mac will sleep: no lid-closed mode, so closing the lid (or idling) ends it, even with
    /// keep-awake on.
    case untilSleep(ssh: String)
    case tailscaleMissing
    case tailscaleOff
    case remoteLoginOff

    /// The first missing piece wins: Tailscale, then Remote Login, then staying on. Only lid-closed mode counts as
    /// staying on: keep-awake holds only while the lid is open. `tailscale` is nil when Tailscale isn't installed.
    public static func evaluate(tailscale: TailscaleStatus?, remoteLogin: Bool, lidClosedMode: Bool,
                                user: String) -> RemoteReach {
        guard let tailscale else { return .tailscaleMissing }
        guard tailscale.online, let host = tailscale.sshHost else { return .tailscaleOff }
        guard remoteLogin else { return .remoteLoginOff }
        let ssh = "ssh \(user)@\(host)"
        return lidClosedMode ? .reachable(ssh: ssh) : .untilSleep(ssh: ssh)
    }

    public var sshCommand: String? {
        switch self {
        case .reachable(let ssh), .untilSleep(let ssh): ssh
        default: nil
        }
    }

    public var isReachable: Bool { sshCommand != nil }

    /// The panel's one line.
    public var text: String {
        switch self {
        case .reachable: "Reachable · Tailscale + SSH"
        case .untilSleep: "Reachable until your Mac sleeps"
        case .tailscaleMissing: "Tailscale isn't installed"
        case .tailscaleOff: "Tailscale is off"
        case .remoteLoginOff: "Remote Login is off"
        }
    }

    /// For the status summary.
    public var sentence: String {
        switch self {
        case .reachable: "Your phone can reach this Mac over Tailscale + SSH."
        case .untilSleep: "Your phone can reach this Mac over Tailscale + SSH until it sleeps."
        default: "Your phone can't reach this Mac: \(text)."
        }
    }
}
