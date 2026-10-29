import Foundation

/// Offers to switch to a trusted Wi-Fi in range while on the hotspot, public Wi-Fi or no Wi-Fi (back home or at the
/// office after being out). Decides when to scan (a scan costs a few seconds of radio, so at most every 2 minutes,
/// backing off to 10 while nothing turns up) and what to offer; asks once per network until you're on a trusted
/// network again or Wi-Fi goes off. Pure: the app scans and switches.
public struct TrustedReturn: Sendable {
    public static let scanInterval: TimeInterval = 120
    public static let maxScanInterval: TimeInterval = 600

    /// The trusted network in range to offer, or nil.
    public private(set) var offer: String?
    private var lastScan: Date?
    private var interval = Self.scanInterval
    private var notified: Set<String> = []
    private var declined: Set<String> = []

    public init() {}

    /// Trusted networks worth switching to: not the hotspot (it counts as trusted, but it's what we're leaving), not
    /// the current one.
    private static func candidates(trusted: [String], hotspot: String, current: String?) -> [String] {
        trusted.filter { $0 != hotspot && $0 != current }
    }

    /// On the hotspot, on Wi-Fi that isn't trusted, or on no Wi-Fi.
    private static func wantsTrusted(current: String?, trusted: [String], hotspot: String) -> Bool {
        guard let current else { return true }
        return current == hotspot || !trusted.contains(current)
    }

    /// Call on every check: ends the episode (and the offer) once there's nothing to switch from or to.
    public mutating func observe(current: String?, wifiOn: Bool, trusted: [String], hotspot: String) {
        let candidates = Self.candidates(trusted: trusted, hotspot: hotspot, current: current)
        guard wifiOn, Self.wantsTrusted(current: current, trusted: trusted, hotspot: hotspot), !candidates.isEmpty else {
            self = TrustedReturn()
            return
        }
        if let offer, !candidates.contains(offer) || declined.contains(offer) {
            self.offer = nil
        }
    }

    public func shouldScan(current: String?, wifiOn: Bool, trusted: [String], hotspot: String, now: Date) -> Bool {
        guard wifiOn, Self.wantsTrusted(current: current, trusted: trusted, hotspot: hotspot),
              !Self.candidates(trusted: trusted, hotspot: hotspot, current: current).isEmpty else { return false }
        return lastScan.map { now.timeIntervalSince($0) >= interval } ?? true
    }

    /// After a scan. Returns the network to notify about: a new one, at most once per episode.
    /// `current` is the Wi-Fi now, after the scan: it may have changed while the scan ran.
    public mutating func scanned(nearby: [String], current: String?, trusted: [String], hotspot: String,
                                 now: Date) -> String? {
        lastScan = now
        guard Self.wantsTrusted(current: current, trusted: trusted, hotspot: hotspot) else {
            offer = nil
            return nil
        }
        let previous = offer
        let inRange = Self.candidates(trusted: trusted, hotspot: hotspot, current: current)
            .filter { nearby.contains($0) && !declined.contains($0) }
        offer = inRange.first
        // A new offer rescans soon; nothing in range, or the same offer still standing, backs off.
        interval = offer == nil || offer == previous ? min(interval * 2, Self.maxScanInterval) : Self.scanInterval
        guard let offer, !notified.contains(offer) else { return nil }
        notified.insert(offer)
        return offer
    }

    /// "Not now": don't offer this network again until the episode ends.
    public mutating func decline(_ ssid: String) {
        declined.insert(ssid)
        if offer == ssid { offer = nil }
    }
}
