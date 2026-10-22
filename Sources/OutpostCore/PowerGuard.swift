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
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var keepingAwake: Bool
    public var lidModeOn: Bool
    public var lowPowerOn: Bool
    public var enabled: Bool

    public init(thermal: ThermalLevel, lidClosed: Bool, onBattery: Bool, batteryPercent: Int?,
                keepingAwake: Bool, lidModeOn: Bool, lowPowerOn: Bool, enabled: Bool) {
        self.thermal = thermal
        self.lidClosed = lidClosed
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.keepingAwake = keepingAwake
        self.lidModeOn = lidModeOn
        self.lowPowerOn = lowPowerOn
        self.enabled = enabled
    }
}

public enum GuardReason: Equatable, Sendable {
    case hot
    case lowBattery(Int)
}

public enum GuardAction: Equatable, Sendable {
    case none
    case enableLowPower
    /// Turn off keep-awake and lid mode, then put the Mac to sleep if the lid is closed.
    case stopAndSleep(GuardReason)
}

/// Protects a closed laptop in a bag: backs off before it overheats or drains.
public enum HotBagGuard {
    public static let lowBatteryPercent = 20

    public static func decide(_ input: GuardInput) -> GuardAction {
        guard input.enabled else { return .none }
        guard input.keepingAwake || input.lidModeOn else { return .none }
        if input.onBattery, let percent = input.batteryPercent, percent <= lowBatteryPercent {
            return .stopAndSleep(.lowBattery(percent))
        }
        let closedInBag = input.lidClosed && input.lidModeOn
        if closedInBag, input.thermal >= .serious {
            return .stopAndSleep(.hot)
        }
        if closedInBag, input.thermal >= .fair, input.onBattery, !input.lowPowerOn {
            return .enableLowPower
        }
        return .none
    }
}

public enum PrivilegedCommandError: LocalizedError, Equatable {
    case notPermitted(String)

    public var errorDescription: String? {
        switch self {
        case .notPermitted(let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Outpost isn't allowed to run this command." : detail
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
