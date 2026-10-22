import XCTest
@testable import AwakeCore

final class FailoverEngineTests: XCTestCase {
    let hotspot = "Phone"
    let home = WiFiState(isPoweredOn: true, ssid: "Home")
    let onHotspot = WiFiState(isPoweredOn: true, ssid: "Phone")
    let disconnected = WiFiState(isPoweredOn: true, ssid: nil)
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    var engine = FailoverEngine(failuresBeforeSwitch: 2, joinRetryDelay: 30, initialReturnDelay: 120,
                                maxReturnDelay: 600, stableAfter: 120)

    private func observe(_ wifi: WiFiState, online: Bool, at seconds: TimeInterval, returnEnabled: Bool = true) -> FailoverEngine.Decision {
        engine.observe(wifi: wifi, online: online, hotspot: hotspot, returnEnabled: returnEnabled,
                       now: t0.addingTimeInterval(seconds))
    }

    func testStaysPutWhileOnline() {
        XCTAssertEqual(observe(home, online: true, at: 0), .none)
        XCTAssertEqual(observe(home, online: true, at: 5), .none)
        XCTAssertEqual(engine.phase, .watching)
    }

    func testSwitchesAfterConsecutiveFailures() {
        XCTAssertEqual(observe(home, online: true, at: 0), .none)
        XCTAssertEqual(observe(home, online: false, at: 5), .none)
        XCTAssertEqual(observe(home, online: false, at: 7), .joinHotspot(leaving: "Home"))
    }

    func testOneGoodCheckResetsTheCount() {
        _ = observe(home, online: false, at: 0)
        _ = observe(home, online: true, at: 5)
        XCTAssertEqual(observe(home, online: false, at: 10), .none)
    }

    func testWiFiDroppingRemembersTheLastGoodNetwork() {
        _ = observe(home, online: true, at: 0)
        _ = observe(disconnected, online: false, at: 5)
        XCTAssertEqual(observe(disconnected, online: false, at: 7), .joinHotspot(leaving: "Home"))
    }

    func testFailedJoinWaitsBeforeRetrying() {
        _ = observe(home, online: false, at: 0)
        XCTAssertEqual(observe(home, online: false, at: 2), .joinHotspot(leaving: "Home"))
        engine.hotspotJoinFailed(now: t0.addingTimeInterval(2))
        XCTAssertEqual(observe(home, online: false, at: 10), .none)
        XCTAssertEqual(observe(home, online: false, at: 33), .joinHotspot(leaving: "Home"))
    }

    func testReturnsHomeAfterTheDelay() {
        engine.joinedHotspot(leaving: "Home", now: t0)
        XCTAssertEqual(observe(onHotspot, online: true, at: 60), .none)
        XCTAssertEqual(observe(onHotspot, online: true, at: 121), .returnToWiFi("Home"))
        // Not asked again until the app reports back and the delay passes.
        XCTAssertEqual(observe(onHotspot, online: true, at: 125), .none)
    }

    func testNoReturnWhenDisabled() {
        engine.joinedHotspot(leaving: "Home", now: t0)
        XCTAssertEqual(observe(onHotspot, online: true, at: 500, returnEnabled: false), .none)
    }

    func testManualHotspotIsLeftAlone() {
        engine.joinedHotspotManually()
        XCTAssertEqual(observe(onHotspot, online: true, at: 10_000), .none)
        XCTAssertEqual(engine.phase, .onHotspot(returnTo: nil))
    }

    func testHotspotJoinedWhileHealthyIsTreatedAsTheUsersChoice() {
        _ = observe(home, online: true, at: 0)
        _ = observe(onHotspot, online: true, at: 5)
        XCTAssertEqual(engine.phase, .onHotspot(returnTo: nil))
    }

    func testHotspotJoinedByMacOSDuringAnOutageCountsAsFailover() {
        _ = observe(home, online: true, at: 0)
        _ = observe(disconnected, online: false, at: 5)
        _ = observe(onHotspot, online: true, at: 8)
        XCTAssertEqual(engine.phase, .onHotspot(returnTo: "Home"))
    }

    func testFailedReturnDoublesTheDelayUpToTheCap() {
        engine.joinedHotspot(leaving: "Home", now: t0)
        XCTAssertEqual(observe(onHotspot, online: true, at: 120), .returnToWiFi("Home"))
        engine.returnAttempted(success: true, now: t0.addingTimeInterval(125))
        // Back home but the internet is still down: switch again and back off.
        _ = observe(home, online: false, at: 130)
        XCTAssertEqual(observe(home, online: false, at: 132), .joinHotspot(leaving: "Home"))
        XCTAssertEqual(engine.returnDelay, 240)

        for _ in 0..<5 {
            engine.returnAttempted(success: true, now: t0.addingTimeInterval(200))
            _ = observe(home, online: false, at: 201)
            _ = observe(home, online: false, at: 202)
        }
        XCTAssertEqual(engine.returnDelay, 600)
    }

    func testStableReturnResetsTheDelay() {
        engine.joinedHotspot(leaving: "Home", now: t0)
        engine.returnAttempted(success: true, now: t0)
        _ = observe(home, online: false, at: 5)
        _ = observe(home, online: false, at: 7)
        XCTAssertEqual(engine.returnDelay, 240)

        engine.returnAttempted(success: true, now: t0.addingTimeInterval(400))
        _ = observe(home, online: true, at: 410)
        _ = observe(home, online: true, at: 530)
        XCTAssertEqual(engine.returnDelay, 120)
    }

    func testFailedReturnRetriesLater() {
        engine.joinedHotspot(leaving: "Home", now: t0)
        XCTAssertEqual(observe(onHotspot, online: true, at: 120), .returnToWiFi("Home"))
        engine.returnAttempted(success: false, now: t0.addingTimeInterval(121))
        XCTAssertEqual(engine.returnDelay, 240, "a failed return backs off too")
        XCTAssertEqual(observe(onHotspot, online: true, at: 300), .none)
        XCTAssertEqual(observe(onHotspot, online: true, at: 362), .returnToWiFi("Home"))
        engine.returnAttempted(success: false, now: t0.addingTimeInterval(362))
        engine.returnAttempted(success: false, now: t0.addingTimeInterval(400))
        XCTAssertEqual(engine.returnDelay, 600, "capped at maxReturnDelay")
    }

    func testWiFiOffOrNoHotspotDoesNothing() {
        let off = WiFiState(isPoweredOn: false, ssid: nil)
        _ = observe(off, online: false, at: 0)
        XCTAssertEqual(observe(off, online: false, at: 5), .none)
        XCTAssertEqual(engine.observe(wifi: home, online: false, hotspot: "", returnEnabled: true, now: t0), .none)
        XCTAssertEqual(engine.observe(wifi: home, online: false, hotspot: "", returnEnabled: true, now: t0), .none)
    }

    func testLeavingTheHotspotGoesBackToWatching() {
        engine.joinedHotspot(leaving: "Home", now: t0)
        XCTAssertEqual(observe(home, online: true, at: 30), .none)
        XCTAssertEqual(engine.phase, .watching)
    }

    private func observe(_ wifi: WiFiState, connectivity: Connectivity, at seconds: TimeInterval) -> FailoverEngine.Decision {
        engine.observe(wifi: wifi, connectivity: connectivity, hotspot: hotspot, returnEnabled: true,
                       now: t0.addingTimeInterval(seconds))
    }

    func testPortalHoldsOffSwitchingUntilTheHoldPasses() {
        engine.portalHold = 90
        let portal = Connectivity.captivePortal(nil)
        XCTAssertEqual(observe(home, connectivity: portal, at: 0), .none)
        XCTAssertEqual(engine.portalSince, t0)
        XCTAssertEqual(observe(home, connectivity: portal, at: 45), .none)
        XCTAssertEqual(observe(home, connectivity: portal, at: 89), .none)
        XCTAssertEqual(observe(home, connectivity: portal, at: 91), .joinHotspot(leaving: "Home"))
    }

    func testSigningInResetsThePortalHold() {
        let portal = Connectivity.captivePortal(nil)
        _ = observe(home, connectivity: portal, at: 0)
        _ = observe(home, connectivity: .online, at: 60)
        XCTAssertNil(engine.portalSince)
        XCTAssertEqual(observe(home, connectivity: portal, at: 100), .none)
        XCTAssertEqual(observe(home, connectivity: portal, at: 150), .none)
        XCTAssertEqual(engine.portalSince, t0.addingTimeInterval(100))
    }

    func testOfflineClearsPortalSince() {
        _ = observe(home, connectivity: .captivePortal(nil), at: 0)
        _ = observe(home, connectivity: .offline, at: 5)
        XCTAssertNil(engine.portalSince)
    }

    func testBoolOverloadMapsToOnlineAndOffline() {
        XCTAssertEqual(observe(home, online: true, at: 0), .none)
        XCTAssertNil(engine.portalSince)
    }
}
