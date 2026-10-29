import XCTest
@testable import AwakeCore

final class OvernightSessionTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testStartedLateAtNightEndsThatMorning() {
        XCTAssertEqual(OvernightSession.nextMorning(hour: 9, after: date(day: 29, 23), calendar: calendar), date(day: 30, 9))
        XCTAssertEqual(OvernightSession.nextMorning(hour: 9, after: date(day: 30, 2), calendar: calendar), date(day: 30, 9))
    }

    func testStartedJustBeforeTheHourRunsToTheNextDay() {
        XCTAssertEqual(OvernightSession.nextMorning(hour: 9, after: date(day: 30, 8, 30), calendar: calendar), date(day: 31, 9))
        XCTAssertEqual(OvernightSession.nextMorning(hour: 9, after: date(day: 30, 7, 59), calendar: calendar), date(day: 30, 9))
    }

    func testStartedDuringTheDayEndsTomorrowMorning() {
        XCTAssertEqual(OvernightSession.nextMorning(hour: 7, after: date(day: 30, 14), calendar: calendar), date(day: 31, 7))
    }

    func testMorningSessionEndsAtItsTime() {
        let session = OvernightSession.start(end: .morning, morningHour: 9, now: date(day: 29, 23), calendar: calendar)
        XCTAssertEqual(session.until, date(day: 30, 9))
        XCTAssertFalse(session.isOver(now: date(day: 30, 8, 59), claudeFinished: true))
        XCTAssertTrue(session.isOver(now: date(day: 30, 9), claudeFinished: false))
    }

    func testClaudeSessionEndsOnlyWhenClaudeFinished() {
        let session = OvernightSession.start(end: .whenClaudeFinishes, morningHour: 9, now: date(day: 29, 23), calendar: calendar)
        XCTAssertNil(session.until)
        XCTAssertFalse(session.isOver(now: date(day: 31, 12), claudeFinished: false))
        XCTAssertTrue(session.isOver(now: date(day: 29, 23, 30), claudeFinished: true))
    }

    func testManualSessionNeverEndsByItself() {
        let session = OvernightSession.start(end: .manually, morningHour: 9, now: date(day: 29, 23), calendar: calendar)
        XCTAssertFalse(session.isOver(now: date(day: 31, 12), claudeFinished: true))
    }

    func testASessionStartedAgainWithTheSameEndIsANewSession() {
        let first = OvernightSession.start(end: .whenClaudeFinishes, morningHour: 9, now: date(day: 29, 23), calendar: calendar)
        let again = OvernightSession.start(end: .whenClaudeFinishes, morningHour: 9, now: date(day: 29, 23, 5), calendar: calendar)
        XCTAssertNotEqual(first, again)
    }

    func testSessionRoundTripsForTheSettingsStore() throws {
        let session = OvernightSession.start(end: .morning, morningHour: 8, now: date(day: 29, 23), calendar: calendar)
        XCTAssertEqual(try JSONDecoder().decode(OvernightSession.self, from: JSONEncoder().encode(session)), session)
    }
}

final class OvernightGuardTests: XCTestCase {
    private func input(thermal: ThermalLevel, onBattery: Bool = false, weakCharger: Bool = false, percent: Int? = 80,
                       lowPower: Bool = false, overnight: Bool = true) -> GuardInput {
        GuardInput(thermal: thermal, lidClosed: true, externalDisplay: false, onBattery: onBattery,
                   chargerTooWeak: weakCharger, batteryPercent: percent, keepingAwake: false, lidModeOn: true,
                   lowPowerOn: lowPower, enabled: true, overnight: overnight)
    }

    func testOvernightOnAChargerStopsOnlyAtCriticalHeat() {
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .serious)), .none)
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .critical)), .stopAndSleep(.hot))
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .serious, overnight: false)), .stopAndSleep(.hot))
    }

    func testOvernightOnBatteryKeepsTheBagRules() {
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .serious, onBattery: true)), .stopAndSleep(.hot))
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .fair, onBattery: true)), .enableLowPower)
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .nominal, onBattery: true, percent: 20)), .stopAndSleep(.lowBattery(20)))
    }

    func testOvernightOnAWeakChargerCountsAsBattery() {
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .serious, weakCharger: true)), .stopAndSleep(.hot))
        XCTAssertEqual(HotBagGuard.decide(input(thermal: .nominal, weakCharger: true, percent: 15)),
                       .stopAndSleep(.lowBattery(15)))
    }
}
