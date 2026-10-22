import Foundation
import IOKit
import IOKit.ps

/// One look at the battery and charger. The raw-values initializer is pure, so the computations can be tested
/// with fixed inputs; `PowerMonitor.read()` supplies live values from IOKit.
public struct PowerReading: Equatable, Sendable {
    /// Battery drain at or above this while plugged in means the charger can't keep up. Below it is noise.
    public static let weakChargerDrawWatts = 1.0

    /// Battery charge in percent; nil on a Mac without a battery.
    public var percent: Int?
    /// Running from the battery.
    public var onBattery: Bool
    /// A charger is plugged in (it may still be too weak to run the Mac).
    public var externalConnected: Bool
    public var isCharging: Bool
    /// Estimated battery time left in minutes; only on battery, nil while macOS is still estimating.
    public var minutesLeft: Int?
    /// Power flowing out of the battery in watts; nil when it isn't draining.
    public var drawWatts: Double?
    /// The charger's rating in watts, when one is plugged in and reports it.
    public var adapterWatts: Int?

    public init(percent: Int?, onBattery: Bool, externalConnected: Bool, isCharging: Bool, minutesLeft: Int?,
                drawWatts: Double?, adapterWatts: Int?) {
        self.percent = percent
        self.onBattery = onBattery
        self.externalConnected = externalConnected
        self.isCharging = isCharging
        self.minutesLeft = minutesLeft
        self.drawWatts = drawWatts
        self.adapterWatts = adapterWatts
    }

    /// From IOKit's raw values: `estimate` is IOPSGetTimeRemainingEstimate (seconds; negative = unknown or on
    /// power), `battery` is AppleSmartBattery's registry entry (Voltage in mV, InstantAmperage in mA, negative while
    /// draining, TimeRemaining in minutes, 65535 = unknown), `adapter` is IOPSCopyExternalPowerAdapterDetails.
    public init(percent: Int?, onBattery: Bool, estimate: Double, battery: [String: Any], adapter: [String: Any]?) {
        let external = battery["ExternalConnected"] as? Bool ?? !onBattery
        var minutes: Int?
        if onBattery {
            if estimate > 0 {
                minutes = Int(estimate / 60)
            } else if let remaining = Self.integer(battery["TimeRemaining"]), remaining > 0, remaining < 65535 {
                minutes = remaining
            }
        }
        var draw: Double?
        if let millivolts = Self.integer(battery["Voltage"]), millivolts > 0,
           let milliamps = Self.integer(battery["InstantAmperage"] ?? battery["Amperage"]), milliamps < 0 {
            draw = Double(millivolts) * Double(-milliamps) / 1_000_000
        }
        self.init(percent: percent, onBattery: onBattery, externalConnected: external,
                  isCharging: battery["IsCharging"] as? Bool ?? false, minutesLeft: minutes, drawWatts: draw,
                  adapterWatts: external ? adapter.flatMap { Self.integer($0["Watts"]) } : nil)
    }

    /// Equal when everything the panel shows matches. The raw draw changes on almost every read, so only whether
    /// it makes the charger too weak counts; comparing it would re-render the panel every few seconds on battery.
    public static func == (lhs: PowerReading, rhs: PowerReading) -> Bool {
        lhs.percent == rhs.percent && lhs.onBattery == rhs.onBattery && lhs.externalConnected == rhs.externalConnected
            && lhs.isCharging == rhs.isCharging && lhs.minutesLeft == rhs.minutesLeft
            && lhs.adapterWatts == rhs.adapterWatts && lhs.chargerTooWeak == rhs.chargerTooWeak
    }

    /// Plugged in, yet the battery keeps draining.
    public var chargerTooWeak: Bool {
        externalConnected && !isCharging && (drawWatts ?? 0) >= Self.weakChargerDrawWatts
    }

    /// The second part of the panel's battery text: time left, charging, or a weak charger.
    public var detail: String? {
        if chargerTooWeak { return adapterWatts.map { "Charger too weak (\($0) W)" } ?? "Charger too weak" }
        if onBattery { return minutesLeft.map { "\(TimeText.format(minutes: $0)) left" } }
        return isCharging ? "Charging" : "On power"
    }

    /// The panel's battery text, e.g. "82% · 3 hr 10 min left" or "64% · Charging". Nil without a battery.
    public var headerText: String? {
        percent.map { ["\($0)%", detail].compactMap { $0 }.joined(separator: " · ") }
    }

    /// For the status summary.
    public var sentence: String? {
        guard let percent else { return nil }
        if chargerTooWeak {
            let charger = adapterWatts.map { "the \($0) W charger" } ?? "the charger"
            return "Battery \(percent)%: \(charger) is too weak, so the battery is still draining."
        }
        if onBattery {
            var text = "Battery \(percent)%"
            if let minutesLeft { text += ", about \(TimeText.format(minutes: minutesLeft)) left" }
            if let drawWatts { text += " (drawing \(Int(drawWatts.rounded())) W)" }
            return text + "."
        }
        return "Battery \(percent)%, \(isCharging ? "charging" : "on power")."
    }

    /// Registry numbers can hold a negative value as its unsigned bit pattern; read them as signed.
    static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
    }
}

public enum PowerMonitor {
    /// Every AppleSmartBattery key `PowerReading` reads; `Amperage` is the fallback when `InstantAmperage` is missing.
    static let batteryKeys = ["ExternalConnected", "IsCharging", "Voltage", "InstantAmperage", "Amperage", "TimeRemaining"]

    public static func read() -> PowerReading {
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        return PowerReading(percent: PowerSource.batteryLevel(), onBattery: PowerSource.isOnBattery(),
                            estimate: IOPSGetTimeRemainingEstimate(), battery: smartBattery(), adapter: adapter)
    }

    private static func smartBattery() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var values: [String: Any] = [:]
        for key in batteryKeys {
            values[key] = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        return values
    }
}

public enum PowerAlert: Equatable, Sendable {
    /// Battery time left fell under the warning threshold.
    case findOutlet(minutesLeft: Int)
    /// Plugged in, but the battery keeps draining.
    case weakCharger(watts: Int?)
}

/// When to warn about power: one "find an outlet" per discharge, and one "charger too weak" per plug-in once the
/// battery has kept draining for `weakChargerHold` (a fresh plug-in takes a moment to start charging).
public struct PowerAlerts: Sendable {
    /// The warning thresholds offered in Settings, in minutes.
    public static let warningChoices = [15, 30, 60]
    public static let defaultWarning = 30
    public static let weakChargerHold: TimeInterval = 60

    private var outletWarned = false
    private var weakWarned = false
    private var weakSince: Date?

    public init() {}

    public mutating func observe(_ reading: PowerReading, warnUnderMinutes threshold: Int, now: Date) -> [PowerAlert] {
        var alerts: [PowerAlert] = []
        if !reading.onBattery {
            outletWarned = false
        } else if let left = reading.minutesLeft, left < threshold, !outletWarned {
            outletWarned = true
            alerts.append(.findOutlet(minutesLeft: left))
        }

        if !reading.externalConnected {
            weakWarned = false
            weakSince = nil
        } else if reading.chargerTooWeak {
            let since = weakSince ?? now
            weakSince = since
            if !weakWarned, now.timeIntervalSince(since) >= Self.weakChargerHold {
                weakWarned = true
                alerts.append(.weakCharger(watts: reading.adapterWatts))
            }
        } else {
            weakSince = nil
        }
        return alerts
    }
}

public enum TimeText {
    /// "45 min", "2 hr", "3 hr 10 min". Partial minutes round up.
    public static func format(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    public static func format(minutes: Int) -> String {
        format(TimeInterval(minutes) * 60)
    }
}
