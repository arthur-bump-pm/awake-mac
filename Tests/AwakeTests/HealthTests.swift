import XCTest
@testable import AwakeCore

final class CPUTicksTests: XCTestCase {
    func testBusyFractionCountsUserSystemAndNice() {
        let earlier = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let later = CPUTicks(user: 400, system: 100, idle: 1400, nice: 100)
        XCTAssertEqual(later.busyFraction(since: earlier)!, 0.4, accuracy: 0.0001)  // 400 busy of 1000
    }

    func testCountersThatWrappedStillGiveTheRightShare() {
        let earlier = CPUTicks(user: UInt32.max - 99, system: 0, idle: UInt32.max - 99, nice: 0)
        let later = CPUTicks(user: 100, system: 0, idle: 100, nice: 0)
        XCTAssertEqual(later.busyFraction(since: earlier)!, 0.5, accuracy: 0.0001)
    }

    func testNoTimePassedIsNil() {
        let ticks = CPUTicks(user: 1, system: 1, idle: 1, nice: 1)
        XCTAssertNil(ticks.busyFraction(since: ticks))
    }

    func testTopProcessFromPs() {
        XCTAssertEqual(HealthMonitor.topProcess(inPsOutput: " 98.4 python\n 26.2 Google Chrome Helper (Renderer)\n"), "python")
        XCTAssertEqual(HealthMonitor.topProcess(inPsOutput: "120.0 Google Chrome Helper (Renderer)\n"),
                       "Google Chrome Helper (Renderer)")
        XCTAssertNil(HealthMonitor.topProcess(inPsOutput: ""))
        XCTAssertNil(HealthMonitor.topProcess(inPsOutput: "ps: not permitted\n"))
    }
}

final class HealthWatchTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let gb: Int64 = 1_000_000_000

    private func sample(cpu: CPUTicks? = nil, memory: MemoryPressure? = .normal, disk: Int64? = nil,
                        discharging: Bool = false) -> HealthSample {
        HealthSample(cpu: cpu, memory: memory, diskFreeBytes: disk, discharging: discharging)
    }

    func testDiskWarnsUnderTenGBOnceAndClearsAboveTwelve() {
        var watch = HealthWatch(cores: 8)
        XCTAssertEqual(watch.observe(sample(disk: 11 * gb), now: start), [])
        XCTAssertEqual(watch.observe(sample(disk: 9 * gb), now: start), [.diskAlmostFull(freeBytes: 9 * gb)])
        XCTAssertEqual(watch.warnings, [.diskAlmostFull(freeBytes: 9 * gb)])
        // Hovering between the lines keeps the warning without notifying again.
        XCTAssertEqual(watch.observe(sample(disk: 11 * gb), now: start), [])
        XCTAssertEqual(watch.warnings, [.diskAlmostFull(freeBytes: 11 * gb)])
        XCTAssertEqual(watch.observe(sample(disk: 13 * gb), now: start), [])
        XCTAssertEqual(watch.warnings, [])
        XCTAssertEqual(watch.observe(sample(disk: 8 * gb), now: start), [.diskAlmostFull(freeBytes: 8 * gb)])
    }

    func testDiskReadingIsKeptBetweenReads() {
        var watch = HealthWatch(cores: 8)
        _ = watch.observe(sample(disk: 5 * gb), now: start)
        XCTAssertEqual(watch.observe(sample(disk: nil), now: start.addingTimeInterval(5)), [])
        XCTAssertEqual(watch.warnings, [.diskAlmostFull(freeBytes: 5 * gb)])
    }

    func testMemoryWarnsOnlyAfterAMinuteAndNotifiesAtMostHourly() {
        var watch = HealthWatch(cores: 8)
        XCTAssertEqual(watch.observe(sample(memory: .warning), now: start), [])
        XCTAssertEqual(watch.observe(sample(memory: .warning), now: start.addingTimeInterval(59)), [])
        XCTAssertEqual(watch.observe(sample(memory: .critical), now: start.addingTimeInterval(60)), [.lowMemory(critical: true)])
        XCTAssertEqual(watch.warnings, [.lowMemory(critical: true)])

        XCTAssertEqual(watch.observe(sample(memory: .normal), now: start.addingTimeInterval(70)), [])
        XCTAssertEqual(watch.warnings, [])
        // A second episode within the hour shows in the panel but doesn't notify.
        _ = watch.observe(sample(memory: .warning), now: start.addingTimeInterval(100))
        XCTAssertEqual(watch.observe(sample(memory: .warning), now: start.addingTimeInterval(160)), [])
        XCTAssertEqual(watch.warnings, [.lowMemory(critical: false)])

        _ = watch.observe(sample(memory: .normal), now: start.addingTimeInterval(200))
        _ = watch.observe(sample(memory: .warning), now: start.addingTimeInterval(3700))
        XCTAssertEqual(watch.observe(sample(memory: .warning), now: start.addingTimeInterval(3760)), [.lowMemory(critical: false)])
    }

    /// Feeds CPU samples every 5 s for `seconds`, `busy` of every 8 ticks per core busy, starting at `from`.
    private func feed(_ watch: inout HealthWatch, from: inout (Date, CPUTicks), seconds: Int, busyCores: Double,
                      discharging: Bool = true) -> [HealthWarning] {
        var started: [HealthWarning] = []
        let cores = Double(watch.cores)
        for _ in 0..<(seconds / 5) {
            let total = 500.0 * cores  // 100 ticks a second per core
            let busy = UInt32(total * busyCores / cores)
            var ticks = from.1
            ticks.user &+= busy
            ticks.idle &+= UInt32(total) - busy
            from = (from.0.addingTimeInterval(5), ticks)
            started += watch.observe(sample(cpu: ticks, discharging: discharging), now: from.0)
        }
        return started
    }

    func testBusyCPUOnBatteryWarnsAfterTenMinutesOnce() {
        var watch = HealthWatch(cores: 8)
        var clock = (start, CPUTicks(user: 0, system: 0, idle: 0, nice: 0))
        _ = watch.observe(sample(cpu: clock.1, discharging: true), now: clock.0)
        XCTAssertEqual(feed(&watch, from: &clock, seconds: 595, busyCores: 2), [])
        XCTAssertEqual(feed(&watch, from: &clock, seconds: 10, busyCores: 2), [.busyCPU])
        XCTAssertEqual(watch.recentBusyCores!, 2, accuracy: 0.01)
        XCTAssertEqual(feed(&watch, from: &clock, seconds: 60, busyCores: 2), [], "one notification per discharge")
        XCTAssertEqual(watch.warnings, [.busyCPU])
    }

    func testBusyCPUClearsWhenItCalmsDownOrIsPluggedIn() {
        var watch = HealthWatch(cores: 8)
        var clock = (start, CPUTicks(user: 0, system: 0, idle: 0, nice: 0))
        _ = watch.observe(sample(cpu: clock.1, discharging: true), now: clock.0)
        _ = feed(&watch, from: &clock, seconds: 610, busyCores: 2)
        XCTAssertEqual(watch.warnings, [.busyCPU])
        _ = feed(&watch, from: &clock, seconds: 30, busyCores: 0.2)
        XCTAssertEqual(watch.warnings, [.busyCPU], "a short lull doesn't clear it")
        _ = feed(&watch, from: &clock, seconds: 60, busyCores: 0.2)
        XCTAssertEqual(watch.warnings, [])

        _ = feed(&watch, from: &clock, seconds: 610, busyCores: 2)
        XCTAssertEqual(watch.warnings, [.busyCPU])
        _ = feed(&watch, from: &clock, seconds: 5, busyCores: 2, discharging: false)
        XCTAssertEqual(watch.warnings, [])
    }

    func testBusyCPUNeedsTenMinutesOnBatteryAndOneBusyCore() {
        var watch = HealthWatch(cores: 8)
        var clock = (start, CPUTicks(user: 0, system: 0, idle: 0, nice: 0))
        _ = watch.observe(sample(cpu: clock.1), now: clock.0)
        XCTAssertEqual(feed(&watch, from: &clock, seconds: 900, busyCores: 4, discharging: false), [])
        // Unplugged just now: the 10 minutes start here, though the CPU was busy before.
        XCTAssertEqual(feed(&watch, from: &clock, seconds: 300, busyCores: 4), [])
        XCTAssertEqual(feed(&watch, from: &clock, seconds: 310, busyCores: 4), [.busyCPU])

        var light = HealthWatch(cores: 8)
        var lightClock = (start, CPUTicks(user: 0, system: 0, idle: 0, nice: 0))
        _ = light.observe(sample(cpu: lightClock.1, discharging: true), now: lightClock.0)
        XCTAssertEqual(feed(&light, from: &lightClock, seconds: 1200, busyCores: 0.8), [])
    }

    func testWarningsComeInAFixedOrder() {
        var watch = HealthWatch(cores: 8)
        _ = watch.observe(sample(memory: .warning, disk: 2 * gb), now: start)
        _ = watch.observe(sample(memory: .warning), now: start.addingTimeInterval(61))
        XCTAssertEqual(watch.warnings.map(\.kind), [.disk, .memory])
    }
}

final class HealthMonitorLiveTests: XCTestCase {
    /// The live readers need no permission, so they answer on any Mac.
    func testLiveReadersAnswer() throws {
        let first = try XCTUnwrap(HealthMonitor.cpuTicks())
        Thread.sleep(forTimeInterval: 0.2)
        let fraction = try XCTUnwrap(HealthMonitor.cpuTicks()?.busyFraction(since: first))
        XCTAssertTrue((0...1).contains(fraction))
        XCTAssertNotNil(HealthMonitor.memoryPressure())
        XCTAssertGreaterThan(try XCTUnwrap(HealthMonitor.diskFreeBytes()), 0)
    }
}
