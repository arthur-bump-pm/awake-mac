import Foundation

public enum LidModeError: LocalizedError, Equatable {
    case needsSetUp
    case setUpCancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .needsSetUp: "Lid-closed mode needs a one-time setup."
        case .setUpCancelled: "Setup was cancelled."
        case .failed(let output): output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Lid-closed mode: macOS's `pmset disablesleep`, which stops all sleep including closing the lid.
/// It needs root, so a one-time setup installs a sudoers rule that allows exactly the commands in
/// `allowedCommands` without a password (lid mode, Low Power Mode, sleep now, firewall).
@MainActor
public final class LidModeController: ObservableObject {
    public nonisolated static let sudoersPath = "/etc/sudoers.d/awake"

    /// Bump whenever `allowedCommands` changes, so existing installs are asked to set up again.
    public nonisolated static let ruleVersion = 2
    public nonisolated static let ruleVersionKey = "privilegedRuleVersion"

    public nonisolated static let allowedCommands = [
        "/usr/bin/pmset -a disablesleep 0",
        "/usr/bin/pmset -a disablesleep 1",
        "/usr/bin/pmset -b lowpowermode 0",
        "/usr/bin/pmset -b lowpowermode 1",
        "/usr/bin/pmset sleepnow",
        "\(FirewallController.tool) --setglobalstate on",
        "\(FirewallController.tool) --setglobalstate off",
        "\(FirewallController.tool) --setstealthmode on",
        "\(FirewallController.tool) --setstealthmode off",
    ]

    @Published public private(set) var isEnabled = false
    /// The rule is installed and current.
    @Published public private(set) var isSetUp = false

    private let runner: CommandRunning
    private let fileExists: (String) -> Bool
    private let defaults: UserDefaults
    /// `pmset` runs here, off the main actor and one command at a time, so reads and changes stay in order.
    private let commands = DispatchQueue(label: "Awake.lidMode")
    /// Reads are numbered as they're queued; an older one never overwrites a newer one.
    private var queuedReads = 0
    private var appliedRead = 0

    public init(runner: CommandRunning = ProcessCommandRunner(),
                fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                defaults: UserDefaults = .standard) {
        self.runner = runner
        self.fileExists = fileExists
        self.defaults = defaults
        refreshNow()
    }

    /// Re-reads the system setting, which another tool or a person may have changed. `pmset` runs off the main actor.
    public func refresh() async {
        await queue { runner in ((), Self.readSleepDisabled(runner)) }
    }

    /// `refresh()` that blocks on `pmset`: for launch and quit only.
    public func refreshNow() {
        queuedReads += 1
        appliedRead = queuedReads
        let runner = self.runner
        apply(sleepDisabled: commands.sync { Self.readSleepDisabled(runner) })
    }

    /// Switches lid-closed mode through the sudoers rule, off the main actor.
    public func setEnabled(_ enabled: Bool) async throws {
        let result = await queue { runner in
            (runner.run("/usr/bin/sudo", ["-n"] + Self.pmsetCommand(enabled)), Self.readSleepDisabled(runner))
        }
        try check(result)
    }

    /// `setEnabled` that blocks on `pmset`: for quitting, which can't wait for the main actor.
    public func setEnabledNow(_ enabled: Bool) throws {
        queuedReads += 1
        appliedRead = queuedReads
        let runner = self.runner
        let (result, disabled) = commands.sync {
            (runner.run("/usr/bin/sudo", ["-n"] + Self.pmsetCommand(enabled)), Self.readSleepDisabled(runner))
        }
        apply(sleepDisabled: disabled)
        try check(result)
    }

    /// Shows the macOS admin password prompt and installs the sudoers rule.
    public func setUp(userName: String = NSUserName()) async throws {
        guard let rule = Self.sudoersRule(for: userName) else {
            throw LidModeError.failed("Unsupported user name: \(userName)")
        }
        let script = Self.appleScript(runningAsAdmin: Self.installScript(rule: rule))
        let runner = self.runner
        let result = await Task.detached { runner.run("/usr/bin/osascript", ["-e", script]) }.value
        if result.status == 0 {
            defaults.set(Self.ruleVersion, forKey: Self.ruleVersionKey)
        }
        await refresh()
        guard result.status == 0 else {
            throw result.output.contains("-128") ? LidModeError.setUpCancelled : LidModeError.failed(result.output)
        }
    }

    /// Runs `work` on the command queue; the sleep setting it read back is applied unless a newer read already was.
    private func queue<T: Sendable>(_ work: @escaping @Sendable (CommandRunning) -> (T, Bool)) async -> T {
        queuedReads += 1
        let read = queuedReads
        let runner = self.runner, commands = self.commands
        let (value, disabled) = await withCheckedContinuation { continuation in
            commands.async { continuation.resume(returning: work(runner)) }
        }
        if read > appliedRead {
            appliedRead = read
            apply(sleepDisabled: disabled)
        }
        return value
    }

    private func check(_ result: CommandResult) throws {
        guard result.status == 0 else {
            throw isSetUp ? LidModeError.failed(result.output) : LidModeError.needsSetUp
        }
    }

    /// Publishes only what changed, so a periodic read doesn't redraw the panel.
    private func apply(sleepDisabled: Bool) {
        if isEnabled != sleepDisabled { isEnabled = sleepDisabled }
        let setUp = fileExists(Self.sudoersPath) && defaults.integer(forKey: Self.ruleVersionKey) >= Self.ruleVersion
        if isSetUp != setUp { isSetUp = setUp }
    }

    private nonisolated static func readSleepDisabled(_ runner: CommandRunning) -> Bool {
        sleepDisabled(inPmsetOutput: runner.run("/usr/bin/pmset", ["-g"]).output)
    }

    // MARK: - Pure helpers

    public nonisolated static func pmsetCommand(_ enabled: Bool) -> [String] {
        ["/usr/bin/pmset", "-a", "disablesleep", enabled ? "1" : "0"]
    }

    public nonisolated static func sleepDisabled(inPmsetOutput output: String) -> Bool {
        output.range(of: #"SleepDisabled\s+1\b"#, options: .regularExpression) != nil
    }

    /// The sudoers line, or nil if the user name has characters that could change its meaning.
    public nonisolated static func sudoersRule(for userName: String) -> String? {
        guard userName.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return nil }
        return "\(userName) ALL=(root) NOPASSWD: \(allowedCommands.joined(separator: ", "))\n"
    }

    /// Root shell script: validate the rule with visudo before it goes live, so a bad file can't break sudo.
    public nonisolated static func installScript(rule: String) -> String {
        """
        set -e
        tmp=$(/usr/bin/mktemp /tmp/awake-sudoers.XXXXXX)
        /usr/bin/printf '%s' '\(rule)' > "$tmp"
        /usr/sbin/visudo -cf "$tmp" >/dev/null
        /usr/sbin/chown root:wheel "$tmp"
        /bin/chmod 0440 "$tmp"
        /bin/mv -f "$tmp" \(sudoersPath)
        """
    }

    public nonisolated static func appleScript(runningAsAdmin shellScript: String) -> String {
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with prompt \"Awake needs your password once, to keep your Mac running with the lid closed and to switch power and firewall settings while you're on the move.\" with administrator privileges"
    }
}
