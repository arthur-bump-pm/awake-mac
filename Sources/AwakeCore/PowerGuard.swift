import Foundation

public enum ThermalLevel: Int, Comparable, Sendable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct GuardInput: Equatable, Sendable {
    public var thermal: ThermalLevel
    public var lidClosed: Bool
    /// An external display is on. With the lid closed that's clamshell mode at a desk, not a laptop in a bag.
    public var externalDisplay: Bool
    /// Running from the battery, as macOS reports it.
    public var onBattery: Bool
    /// Plugged in, but the charger (or power bank) can't keep up, so the battery still drains. macOS reports that
    /// as AC power.
    public var chargerTooWeak: Bool
    public var batteryPercent: Int?
    public var keepingAwake: Bool
    public var lidModeOn: Bool
    public var lowPowerOn: Bool
    public var enabled: Bool
    /// An Overnight session is on: the user left the Mac to run, on a desk rather than in a bag.
    public var overnight: Bool

    public init(thermal: ThermalLevel, lidClosed: Bool, externalDisplay: Bool, onBattery: Bool, chargerTooWeak: Bool,
                batteryPercent: Int?, keepingAwake: Bool, lidModeOn: Bool, lowPowerOn: Bool, enabled: Bool,
                overnight: Bool = false) {
        self.thermal = thermal
        self.lidClosed = lidClosed
        self.externalDisplay = externalDisplay
        self.onBattery = onBattery
        self.chargerTooWeak = chargerTooWeak
        self.batteryPercent = batteryPercent
        self.keepingAwake = keepingAwake
        self.lidModeOn = lidModeOn
        self.lowPowerOn = lowPowerOn
        self.enabled = enabled
        self.overnight = overnight
    }

    /// The battery is running down: on battery, or on a charger too weak to keep up.
    public var discharging: Bool { onBattery || chargerTooWeak }
}

public enum GuardReason: Equatable, Sendable {
    case hot
    case lowBattery(Int)
}

public enum GuardAction: Equatable, Sendable {
    case none
    case enableLowPower
    /// Turn off keep-awake and lid mode, then put the Mac to sleep if the lid is closed (see `shouldSleepNow`).
    case stopAndSleep(GuardReason)
}

/// Protects a closed laptop in a bag: backs off before it overheats or drains.
public enum HotBagGuard {
    public static let lowBatteryPercent = 20

    public static func decide(_ input: GuardInput) -> GuardAction {
        guard input.enabled else { return .none }
        guard input.keepingAwake || input.lidModeOn else { return .none }
        if input.discharging, let percent = input.batteryPercent, percent <= lowBatteryPercent {
            return .stopAndSleep(.lowBattery(percent))
        }
        let closed = input.lidClosed && input.lidModeOn && !input.externalDisplay
        // Overnight on a charger is a Mac left running on a desk, not one in a bag: only critical heat stops it (macOS
        // throttles it before that). On battery, Overnight gets the bag rules, since nothing says it's on a desk.
        let onDeskOvernight = input.overnight && !input.discharging
        if closed, input.thermal >= (onDeskOvernight ? .critical : .serious) {
            return .stopAndSleep(.hot)
        }
        // `pmset -b lowpowermode` only applies on battery power, so a weak charger doesn't count here.
        if closed, input.thermal >= .fair, input.onBattery, !input.lowPowerOn {
            return .enableLowPower
        }
        return .none
    }

    /// Whether to put the Mac to sleep after stopping: only with the lid closed, and never in clamshell mode at a
    /// desk (an external display on), where the Mac is in use.
    public static func shouldSleepNow(lidClosed: Bool, externalDisplay: Bool) -> Bool {
        lidClosed && !externalDisplay
    }
}

/// Lets the guard act once per episode. When a stop can't take (lid-closed mode won't turn off), the guard would
/// otherwise stop, notify and sleep again every 30 s and on every thermal change. A new episode starts once the guard
/// has nothing to do.
public struct GuardEpisode: Sendable {
    private var stopped = false

    public init() {}

    /// The action to take now: `action`, or `.none` when this episode already stopped.
    public mutating func filter(_ action: GuardAction) -> GuardAction {
        switch action {
        case .none:
            stopped = false
            return .none
        case .enableLowPower:
            return action
        case .stopAndSleep:
            guard !stopped else { return .none }
            stopped = true
            return action
        }
    }
}

public enum PrivilegedCommandError: LocalizedError, Equatable {
    case notPermitted(String)

    public var errorDescription: String? {
        switch self {
        case .notPermitted(let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Awake isn't allowed to run this command." : detail
        }
    }
}

/// Low Power Mode on battery, through `pmset -b lowpowermode`.
public final class LowPowerModeController: @unchecked Sendable {
    private let runner: CommandRunning

    public init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    /// Whether Low Power Mode is on for battery power, or nil if `pmset` doesn't report it.
    public func isOnForBattery() -> Bool? {
        Self.lowPowerOnBattery(inPmsetCustomOutput: runner.run("/usr/bin/pmset", ["-g", "custom"]).output)
    }

    public func setForBattery(_ on: Bool) throws {
        let command = Self.command(on)
        let result = runner.run(command[0], Array(command.dropFirst()))
        guard result.status == 0 else { throw PrivilegedCommandError.notPermitted(result.output) }
    }

    public static func command(_ on: Bool) -> [String] {
        ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-b", "lowpowermode", on ? "1" : "0"]
    }

    static func lowPowerOnBattery(inPmsetCustomOutput output: String) -> Bool? {
        var inBatterySection = false
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" "), !line.hasPrefix("\t"), trimmed.hasSuffix(":") {
                inBatterySection = trimmed == "Battery Power:"
                continue
            }
            guard inBatterySection else { continue }
            let fields = trimmed.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0] == "lowpowermode" { return fields[1] == "1" }
        }
        return nil
    }
}

public enum SystemSleep {
    /// Sleeps the Mac now. Plain `pmset sleepnow` works for the logged-in user; sudo is the fallback.
    @discardableResult
    public static func sleepNow(runner: CommandRunning = ProcessCommandRunner()) -> Bool {
        if runner.run("/usr/bin/pmset", ["sleepnow"]).status == 0 { return true }
        return runner.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "sleepnow"]).status == 0
    }
}
