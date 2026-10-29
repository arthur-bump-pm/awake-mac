import XCTest
@testable import AwakeCore

final class TrustedReturnTests: XCTestCase {
    private let trusted = ["Home Network", "Studio 5G", "Travel Phone"]
    private let hotspot = "Travel Phone"
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testOnTheHotspotScansAndOffersATrustedNetworkInRangeOnce() {
        var offer = TrustedReturn()
        offer.observe(current: hotspot, wifiOn: true, trusted: trusted, hotspot: hotspot)
        XCTAssertTrue(offer.shouldScan(current: hotspot, wifiOn: true, trusted: trusted, hotspot: hotspot, now: start))
        XCTAssertEqual(offer.scanned(nearby: ["Café", "Home Network"], current: hotspot, trusted: trusted, hotspot: hotspot,
                                     now: start), "Home Network")
        XCTAssertEqual(offer.offer, "Home Network")
        XCTAssertNil(offer.scanned(nearby: ["Home Network"], current: hotspot, trusted: trusted, hotspot: hotspot,
                                   now: start.addingTimeInterval(120)), "asks once")
        XCTAssertEqual(offer.offer, "Home Network", "the panel keeps offering it")
    }

    func testPublicWiFiAndNoWiFiCountToo() {
        for current in ["Harbourside Guest", nil] as [String?] {
            var offer = TrustedReturn()
            XCTAssertTrue(offer.shouldScan(current: current, wifiOn: true, trusted: trusted, hotspot: hotspot, now: start))
            XCTAssertEqual(offer.scanned(nearby: ["Studio 5G"], current: current, trusted: trusted, hotspot: hotspot, now: start),
                           "Studio 5G")
        }
    }

    func testNothingToDoOnATrustedNetworkWithWiFiOffOrWithoutTrustedNetworks() {
        let offer = TrustedReturn()
        XCTAssertFalse(offer.shouldScan(current: "Home Network", wifiOn: true, trusted: trusted, hotspot: hotspot, now: start))
        XCTAssertFalse(offer.shouldScan(current: hotspot, wifiOn: false, trusted: trusted, hotspot: hotspot, now: start))
        XCTAssertFalse(offer.shouldScan(current: hotspot, wifiOn: true, trusted: [hotspot], hotspot: hotspot, now: start),
                       "the hotspot alone is nothing to switch to")
    }

    func testScansBackOffWhileNothingTurnsUp() {
        var offer = TrustedReturn()
        var now = start
        for expected in [240.0, 480, 600, 600] {
            _ = offer.scanned(nearby: [], current: hotspot, trusted: trusted, hotspot: hotspot, now: now)
            XCTAssertFalse(offer.shouldScan(current: hotspot, wifiOn: true, trusted: trusted, hotspot: hotspot,
                                            now: now.addingTimeInterval(expected - 1)))
            XCTAssertTrue(offer.shouldScan(current: hotspot, wifiOn: true, trusted: trusted, hotspot: hotspot,
                                           now: now.addingTimeInterval(expected)))
            now = now.addingTimeInterval(expected)
        }
    }

    func testNotNowHidesThatNetworkUntilTheEpisodeEnds() {
        var offer = TrustedReturn()
        _ = offer.scanned(nearby: ["Home Network", "Studio 5G"], current: hotspot, trusted: trusted, hotspot: hotspot, now: start)
        offer.decline("Home Network")
        XCTAssertNil(offer.offer)
        XCTAssertEqual(offer.scanned(nearby: ["Home Network", "Studio 5G"], current: hotspot, trusted: trusted, hotspot: hotspot,
                                     now: start.addingTimeInterval(120)), "Studio 5G")

        // On a trusted network the episode ends; out again later, Home Network is offered (and asked about) again.
        offer.observe(current: "Studio 5G", wifiOn: true, trusted: trusted, hotspot: hotspot)
        XCTAssertNil(offer.offer)
        offer.observe(current: hotspot, wifiOn: true, trusted: trusted, hotspot: hotspot)
        XCTAssertEqual(offer.scanned(nearby: ["Home Network"], current: hotspot, trusted: trusted, hotspot: hotspot,
                                     now: start.addingTimeInterval(600)), "Home Network")
    }

    func testAScanThatEndsOnATrustedNetworkOffersNothing() {
        var offer = TrustedReturn()
        // The scan started on the hotspot; macOS joined Studio 5G while it ran.
        XCTAssertNil(offer.scanned(nearby: ["Home Network"], current: "Studio 5G", trusted: trusted, hotspot: hotspot, now: start))
        XCTAssertNil(offer.offer)
    }

    func testAnIgnoredOfferBacksOffToo() {
        var offer = TrustedReturn()
        _ = offer.scanned(nearby: ["Home Network"], current: hotspot, trusted: trusted, hotspot: hotspot, now: start)
        _ = offer.scanned(nearby: ["Home Network"], current: hotspot, trusted: trusted, hotspot: hotspot,
                          now: start.addingTimeInterval(120))
        XCTAssertFalse(offer.shouldScan(current: hotspot, wifiOn: true, trusted: trusted, hotspot: hotspot,
                                        now: start.addingTimeInterval(120 + 239)))
        XCTAssertTrue(offer.shouldScan(current: hotspot, wifiOn: true, trusted: trusted, hotspot: hotspot,
                                       now: start.addingTimeInterval(120 + 240)))
    }

    func testAnOfferGoesWhenItsNetworkIsNoLongerTrusted() {
        var offer = TrustedReturn()
        _ = offer.scanned(nearby: ["Home Network"], current: hotspot, trusted: trusted, hotspot: hotspot, now: start)
        offer.observe(current: hotspot, wifiOn: true, trusted: ["Studio 5G", hotspot], hotspot: hotspot)
        XCTAssertNil(offer.offer)
    }
}
