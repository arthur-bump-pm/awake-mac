import Foundation

/// Decides when to move to the hotspot and when to try going back to Wi-Fi.
/// Pure logic: the app feeds it one observation per check, carries out the decision,
/// and reports the outcome back.
public struct FailoverEngine: Sendable {
    public enum Phase: Equatable, Sendable {
        case watching
        /// On the hotspot. `returnTo` is the Wi-Fi to go back to; nil when the user chose the hotspot.
        case onHotspot(returnTo: String?)
    }

    public enum Decision: Equatable, Sendable {
        case none
        case joinHotspot(leaving: String?)
        case returnToWiFi(String)
    }

    /// Failed checks in a row before switching (checks run every few seconds).
    public var failuresBeforeSwitch: Int
    /// Wait after a failed hotspot join before trying again.
    public var joinRetryDelay: TimeInterval
    public var initialReturnDelay: TimeInterval
    public var maxReturnDelay: TimeInterval
    /// How long Wi-Fi must stay online after going back before the return delay resets.
    public var stableAfter: TimeInterval
    /// How long a sign-in page may be showing before the Wi-Fi counts as down.
    public var portalHold: TimeInterval

    public private(set) var phase: Phase = .watching
    public private(set) var consecutiveFailures = 0
    public private(set) var returnDelay: TimeInterval
    /// Since when a captive portal has been continuously seen; nil when there is none.
    public private(set) var portalSince: Date?
    private var lastGoodSSID: String?
    private var nextJoinAt: Date?
    private var nextReturnAt: Date?
    private var returnedAt: Date?

    public init(failuresBeforeSwitch: Int = 2, joinRetryDelay: TimeInterval = 30,
                initialReturnDelay: TimeInterval = 120, maxReturnDelay: TimeInterval = 1800,
                stableAfter: TimeInterval = 120, portalHold: TimeInterval = 90) {
        self.failuresBeforeSwitch = failuresBeforeSwitch
        self.joinRetryDelay = joinRetryDelay
        self.initialReturnDelay = initialReturnDelay
        self.maxReturnDelay = maxReturnDelay
        self.stableAfter = stableAfter
        self.portalHold = portalHold
        self.returnDelay = initialReturnDelay
    }

    public mutating func observe(wifi: WiFiState, online: Bool, hotspot: String,
                                 returnEnabled: Bool, now: Date) -> Decision {
        observe(wifi: wifi, connectivity: online ? .online : .offline, hotspot: hotspot,
                returnEnabled: returnEnabled, now: now)
    }

    public mutating func observe(wifi: WiFiState, connectivity: Connectivity, hotspot: String,
                                 returnEnabled: Bool, now: Date) -> Decision {
        guard wifi.isPoweredOn, !hotspot.isEmpty else {
            consecutiveFailures = 0
            portalSince = nil
            return .none
        }

        if wifi.ssid == hotspot {
            if case .watching = phase {
                // Joined by macOS or the user. If the internet was failing, treat it as a failover.
                phase = .onHotspot(returnTo: consecutiveFailures > 0 ? lastGoodSSID : nil)
            }
            consecutiveFailures = 0
            portalSince = nil
            guard returnEnabled, case .onHotspot(let home?) = phase else { return .none }
            let due = nextReturnAt ?? now.addingTimeInterval(returnDelay)
            guard now >= due else {
                nextReturnAt = due
                return .none
            }
            nextReturnAt = now.addingTimeInterval(returnDelay)
            return .returnToWiFi(home)
        }

        if case .onHotspot = phase {
            phase = .watching
            nextReturnAt = nil
        }

        if case .captivePortal = connectivity {
            let since = portalSince ?? now
            portalSince = since
            // Give the person time to sign in before spending hotspot data.
            guard now.timeIntervalSince(since) >= portalHold else {
                consecutiveFailures = 0
                return .none
            }
            consecutiveFailures = max(consecutiveFailures, failuresBeforeSwitch - 1)
        } else {
            portalSince = nil
        }

        if connectivity == .online {
            consecutiveFailures = 0
            if let ssid = wifi.ssid {
                lastGoodSSID = ssid
            }
            if let returnedAt, now.timeIntervalSince(returnedAt) >= stableAfter {
                returnDelay = initialReturnDelay
                self.returnedAt = nil
            }
            return .none
        }

        consecutiveFailures += 1
        guard consecutiveFailures >= failuresBeforeSwitch else { return .none }
        if let nextJoinAt, now < nextJoinAt { return .none }
        if let returnedAt, now.timeIntervalSince(returnedAt) < stableAfter {
            // Went back too early; wait longer before the next try.
            returnDelay = min(returnDelay * 2, maxReturnDelay)
        }
        returnedAt = nil
        return .joinHotspot(leaving: wifi.ssid ?? lastGoodSSID)
    }

    public mutating func joinedHotspot(leaving: String?, now: Date) {
        phase = .onHotspot(returnTo: leaving)
        consecutiveFailures = 0
        nextJoinAt = nil
        nextReturnAt = now.addingTimeInterval(returnDelay)
    }

    /// The user picked the hotspot themselves, so don't move them off it.
    public mutating func joinedHotspotManually() {
        phase = .onHotspot(returnTo: nil)
        consecutiveFailures = 0
        nextJoinAt = nil
    }

    public mutating func hotspotJoinFailed(now: Date) {
        nextJoinAt = now.addingTimeInterval(joinRetryDelay)
    }

    public mutating func returnAttempted(success: Bool, now: Date) {
        if success {
            returnedAt = now
        } else {
            // Each failed try drops the hotspot for a moment, so wait longer before the next one.
            returnDelay = min(returnDelay * 2, maxReturnDelay)
        }
        nextReturnAt = now.addingTimeInterval(returnDelay)
    }

    public mutating func reset() {
        self = FailoverEngine(failuresBeforeSwitch: failuresBeforeSwitch, joinRetryDelay: joinRetryDelay,
                              initialReturnDelay: initialReturnDelay, maxReturnDelay: maxReturnDelay,
                              stableAfter: stableAfter, portalHold: portalHold)
    }
}
