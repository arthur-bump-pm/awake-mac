@testable import AwakeCore
import XCTest

final class NetworkTrafficTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func counters(_ pairs: [String: (UInt64, UInt64)]) -> TrafficCounters {
        TrafficCounters(pairs.mapValues { InterfaceCounts(received: $0.0, sent: $0.1) })
    }

    func testRateIsBitsPerSecondOverAllInterfaces() {
        let before = counters(["en0": (1_000, 500), "en7": (0, 0)])
        let after = counters(["en0": (1_000 + 2_000_000, 500 + 250_000), "en7": (500_000, 0)])
        let rate = TrafficRate.between(before, at: start, after, at: start.addingTimeInterval(2))
        XCTAssertEqual(rate, TrafficRate(down: 2_500_000 * 8 / 2, up: 250_000 * 8 / 2))
    }

    func testANewInterfaceIsNotABurst() {
        let before = counters(["en0": (0, 0)])
        let after = counters(["en0": (1_000, 1_000), "en5": (9_000_000_000, 9_000_000_000)])
        let rate = TrafficRate.between(before, at: start, after, at: start.addingTimeInterval(1))
        XCTAssertEqual(rate, TrafficRate(down: 8_000, up: 8_000))
    }

    func testAResetInterfaceIsSkipped() {
        let before = counters(["en0": (5_000_000, 5_000_000), "en1": (0, 0)])
        let after = counters(["en0": (10, 10), "en1": (1_000, 0)])
        let rate = TrafficRate.between(before, at: start, after, at: start.addingTimeInterval(1))
        XCTAssertEqual(rate, TrafficRate(down: 8_000, up: 0))
    }

    func testNoTimePassedIsNoRate() {
        let same = counters(["en0": (1, 1)])
        XCTAssertNil(TrafficRate.between(same, at: start, same, at: start))
        XCTAssertNil(TrafficRate.between(same, at: start, same, at: start.addingTimeInterval(-1)))
    }

    func testCountsOnlyPhysicalInterfaces() {
        for name in ["en0", "en1", "en12"] {
            XCTAssertTrue(TrafficCounters.counts(interface: name), name)
        }
        for name in ["lo0", "utun3", "awdl0", "llw0", "bridge0", "ap1", "anpi0", "gif0"] {
            XCTAssertFalse(TrafficCounters.counts(interface: name), name)
        }
    }

    func testText() {
        XCTAssertEqual(TrafficRate.text(bitsPerSecond: 0), "0 kbps")
        XCTAssertEqual(TrafficRate.text(bitsPerSecond: -5), "0 kbps")
        XCTAssertEqual(TrafficRate.text(bitsPerSecond: 640_000), "640 kbps")
        XCTAssertEqual(TrafficRate.text(bitsPerSecond: 999_600), "1.0 Mbps")
        XCTAssertEqual(TrafficRate.text(bitsPerSecond: 2_140_000), "2.1 Mbps")
        XCTAssertEqual(TrafficRate.text(bitsPerSecond: 9_960_000), "10 Mbps")
        XCTAssertEqual(TrafficRate.text(bitsPerSecond: 84_400_000), "84 Mbps")
        XCTAssertEqual(TrafficRate.text(bitsPerSecond: 999_700_000), "1.0 Gbps")
        XCTAssertEqual(TrafficRate.text(bitsPerSecond: 1_240_000_000), "1.2 Gbps")
        XCTAssertEqual(TrafficRate(down: 84_000_000, up: 2_100_000).text, "↓ 84 Mbps  ↑ 2.1 Mbps")
    }

    /// The live reader works on this Mac and only returns counted interfaces.
    func testLiveRead() throws {
        let counters = try XCTUnwrap(TrafficReader.read())
        XCTAssertTrue(counters.interfaces.keys.allSatisfy(TrafficCounters.counts(interface:)))
    }
}
