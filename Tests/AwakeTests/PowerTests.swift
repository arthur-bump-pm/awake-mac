import XCTest
@testable import AwakeCore

final class PowerReadingTests: XCTestCase {
    /// AppleSmartBattery stores a negative current as its unsigned bit pattern.
    private func registry(_ milliamps: Int) -> NSNumber {
        NSNumber(value: UInt64(bitPattern: Int64(milliamps)))
    }

    private func battery(voltage: Int = 12_000, amperage: Int, charging: Bool = false, external: Bool,
                         timeRemaining: Int = 65535) -> [String: Any] {
        ["Voltage": voltage, "InstantAmperage": registry(amperage), "IsCharging": charging,
         "ExternalConnected": external, "TimeRemaining": timeRemaining]
    }

    func testOnBatteryUsesTheEstimateAndComputesDraw() {
        let reading = PowerReading(percent: 82, onBattery: true, estimate: 11_400,
                                   battery: battery(amperage: -750, external: false), adapter: nil)
        XCTAssertEqual(reading.minutesLeft, 190)
        XCTAssertEqual(try XCTUnwrap(reading.drawWatts), 9.0, accuracy: 0.001)
        XCTAssertFalse(reading.chargerTooWeak)
        XCTAssertEqual(reading.headerText, "82% · 3 hr 10 min left")
        XCTAssertEqual(reading.sentence, "Battery 82%, about 3 hr 10 min left (drawing 9 W).")
    }

    func testFallsBackToTheBatteryTimeRemaining() {
        let reading = PowerReading(percent: 40, onBattery: true, estimate: -1,
                                   battery: battery(amperage: -500, external: false, timeRemaining: 95), adapter: nil)
        XCTAssertEqual(reading.minutesLeft, 95)
        XCTAssertEqual(reading.headerText, "40% · 1 hr 35 min left")
    }

    func testStillEstimatingShowsJustThePercent() {
        let reading = PowerReading(percent: 40, onBattery: true, estimate: -1,
                                   battery: battery(amperage: -500, external: false), adapter: nil)
        XCTAssertNil(reading.minutesLeft)
        XCTAssertEqual(reading.headerText, "40%")
    }

    func testNoTimeLeftOnPower() {
        // On power TimeRemaining is time to full, and the estimate is "unlimited" (-2).
        let reading = PowerReading(percent: 60, onBattery: false, estimate: -2,
                                   battery: battery(amperage: 2_000, charging: true, external: true, timeRemaining: 50),
                                   adapter: ["Watts": 96])
        XCTAssertNil(reading.minutesLeft)
        XCTAssertNil(reading.drawWatts)
        XCTAssertEqual(reading.adapterWatts, 96)
        XCTAssertEqual(reading.headerText, "60% · Charging")
        XCTAssertEqual(reading.sentence, "Battery 60%, charging.")
    }

    func testFullOnPowerIsOnPower() {
        let reading = PowerReading(percent: 100, onBattery: false, estimate: -2,
                                   battery: battery(amperage: 0, external: true), adapter: ["Watts": 60])
        XCTAssertFalse(reading.chargerTooWeak)
        XCTAssertEqual(reading.headerText, "100% · On power")
    }

    func testDrainingWhilePluggedInIsAWeakCharger() {
        let reading = PowerReading(percent: 70, onBattery: false, estimate: -2,
                                   battery: battery(amperage: -1_000, external: true), adapter: ["Watts": 30])
        XCTAssertTrue(reading.chargerTooWeak)
        XCTAssertEqual(reading.headerText, "70% · Charger too weak (30 W)")
        XCTAssertEqual(reading.sentence, "Battery 70%: the 30 W charger is too weak, so the battery is still draining.")
    }

    func testTinyDrainOnPowerIsNoise() {
        let reading = PowerReading(percent: 80, onBattery: false, estimate: -2,
                                   battery: battery(amperage: -40, external: true), adapter: ["Watts": 30])
        XCTAssertFalse(reading.chargerTooWeak)
    }

    func testUnknownWattageStillWarns() {
        let reading = PowerReading(percent: 70, onBattery: false, estimate: -2,
                                   battery: battery(amperage: -1_000, external: true), adapter: nil)
        XCTAssertEqual(reading.detail, "Charger too weak")
    }

    func testNoBatteryHasNoText() {
        let reading = PowerReading(percent: nil, onBattery: false, estimate: -2, battery: [:], adapter: ["Watts": 150])
        XCTAssertNil(reading.headerText)
        XCTAssertNil(reading.sentence)
        XCTAssertFalse(reading.chargerTooWeak)
    }

    func testFallsBackToAmperageAndReadsIt() {
        XCTAssertEqual(Set(PowerMonitor.batteryKeys),
                       ["ExternalConnected", "IsCharging", "Voltage", "InstantAmperage", "Amperage", "TimeRemaining"])
        let reading = PowerReading(percent: 50, onBattery: true, estimate: -1,
                                   battery: ["Voltage": 12_000, "Amperage": registry(-500), "ExternalConnected": false],
                                   adapter: nil)
        XCTAssertEqual(try XCTUnwrap(reading.drawWatts), 6.0, accuracy: 0.001)
    }

    func testDrawAloneDoesNotChangeEquality() {
        // The draw changes on almost every read; the panel doesn't show it, so it mustn't re-render.
        let reading = PowerReading(percent: 50, onBattery: true, externalConnected: false, isCharging: false,
                                   minutesLeft: 120, drawWatts: 7.4, adapterWatts: nil)
        var drawn = reading
        drawn.drawWatts = 9.1
        XCTAssertEqual(reading, drawn)
        var later = reading
        later.minutesLeft = 119
        XCTAssertNotEqual(reading, later)
    }

    func testDrawThatMakesTheChargerTooWeakStillCounts() {
        let fine = PowerReading(percent: 50, onBattery: false, externalConnected: true, isCharging: false,
                                minutesLeft: nil, drawWatts: 0.4, adapterWatts: 30)
        var weak = fine
        weak.drawWatts = 6
        XCTAssertNotEqual(fine, weak)
    }

    func testRegistryIntegersReadSigned() {
        XCTAssertEqual(PowerReading.integer(registry(-1_000)), -1_000)
        XCTAssertEqual(PowerReading.integer(NSNumber(value: 12_486)), 12_486)
        XCTAssertNil(PowerReading.integer("12"))
    }

    func testTimeText() {
        XCTAssertEqual(TimeText.format(minutes: 25), "25 min")
        XCTAssertEqual(TimeText.format(minutes: 60), "1 hr")
        XCTAssertEqual(TimeText.format(minutes: 190), "3 hr 10 min")
        XCTAssertEqual(TimeText.format(61), "2 min")
        XCTAssertEqual(TimeText.spoken(minutes: 15), "15 minutes")
        XCTAssertEqual(TimeText.spoken(minutes: 60), "1 hour")
        XCTAssertEqual(TimeText.spoken(minutes: 240), "4 hours")
        XCTAssertEqual(TimeText.spoken(minutes: 61), "1 hour 1 minute")
    }
}

final class PowerAlertsTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func onBattery(_ minutes: Int?) -> PowerReading {
        PowerReading(percent: 30, onBattery: true, externalConnected: false, isCharging: false, minutesLeft: minutes,
                     drawWatts: 8, adapterWatts: nil)
    }

    private func pluggedIn(drainWatts: Double?) -> PowerReading {
        PowerReading(percent: 50, onBattery: false, externalConnected: true, isCharging: drainWatts == nil,
                     minutesLeft: nil, drawWatts: drainWatts, adapterWatts: 30)
    }

    func testOneOutletWarningPerDischarge() {
        var alerts = PowerAlerts()
        XCTAssertEqual(alerts.observe(onBattery(45), warnUnderMinutes: 30, now: start), [])
        XCTAssertEqual(alerts.observe(onBattery(30), warnUnderMinutes: 30, now: start), [], "under, not at")
        XCTAssertEqual(alerts.observe(onBattery(25), warnUnderMinutes: 30, now: start), [.findOutlet(minutesLeft: 25)])
        XCTAssertEqual(alerts.observe(onBattery(20), warnUnderMinutes: 30, now: start), [])
        XCTAssertEqual(alerts.observe(onBattery(nil), warnUnderMinutes: 30, now: start), [])
        // Plugging in re-arms it for the next discharge.
        XCTAssertEqual(alerts.observe(pluggedIn(drainWatts: nil), warnUnderMinutes: 30, now: start), [])
        XCTAssertEqual(alerts.observe(onBattery(14), warnUnderMinutes: 15, now: start), [.findOutlet(minutesLeft: 14)])
    }

    func testWeakChargerWaitsForTheHoldThenWarnsOncePerPlugIn() {
        var alerts = PowerAlerts()
        let weak = pluggedIn(drainWatts: 6)
        XCTAssertEqual(alerts.observe(weak, warnUnderMinutes: 30, now: start), [])
        XCTAssertEqual(alerts.observe(weak, warnUnderMinutes: 30, now: start + 30), [])
        XCTAssertEqual(alerts.observe(weak, warnUnderMinutes: 30, now: start + 60), [.weakCharger(watts: 30)])
        XCTAssertEqual(alerts.observe(weak, warnUnderMinutes: 30, now: start + 600), [])
        // Unplug and plug the same charger back in: a new plug-in warns again after the hold.
        XCTAssertEqual(alerts.observe(onBattery(200), warnUnderMinutes: 30, now: start + 610), [])
        XCTAssertEqual(alerts.observe(weak, warnUnderMinutes: 30, now: start + 620), [])
        XCTAssertEqual(alerts.observe(weak, warnUnderMinutes: 30, now: start + 680), [.weakCharger(watts: 30)])
    }

    func testABriefDrainAfterPluggingInDoesNotWarn() {
        var alerts = PowerAlerts()
        XCTAssertEqual(alerts.observe(pluggedIn(drainWatts: 6), warnUnderMinutes: 30, now: start), [])
        XCTAssertEqual(alerts.observe(pluggedIn(drainWatts: nil), warnUnderMinutes: 30, now: start + 5), [])
        XCTAssertEqual(alerts.observe(pluggedIn(drainWatts: 6), warnUnderMinutes: 30, now: start + 61), [])
        XCTAssertEqual(alerts.observe(pluggedIn(drainWatts: 6), warnUnderMinutes: 30, now: start + 121), [.weakCharger(watts: 30)])
    }
}
