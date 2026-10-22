import Foundation

/// The firewall shield (macOS firewall + stealth mode). More than one thing can want it, On the Move and public
/// Wi-Fi, but it has one owner and one snapshot: the firewall as it was when the shield went up, put back only
/// once no reason is left. Pure: the app reads and applies the firewall, this decides when and to what.
///
/// A snapshot alone doesn't prove the firewall is shielded: a raise can fail partway, and a crash can land between
/// the snapshot and the commands. So the shield also tracks whether this run has read the firewall back shielded
/// since the snapshot (`verified`, not persisted). Until it has, a wanted shield applies `shielded` again and keeps
/// the snapshot.
public struct FirewallShield: Codable, Equatable, Sendable {
    public static let shielded = FirewallState(enabled: true, stealth: true)

    public enum Step: Equatable, Sendable {
        case none
        /// Snapshot the firewall, then apply `shielded`.
        case raise
        /// Apply `shielded` again and keep the snapshot: the first wanted step after a launch, or a retry after a
        /// raise that only partly applied.
        case reapply
        case lower
    }

    /// The firewall as it was before the shield went up; nil while the shield is down.
    public private(set) var saved: FirewallState?
    /// This run read the firewall back shielded since the snapshot. Not persisted, so a relaunch reapplies.
    public private(set) var verified = false

    private enum CodingKeys: String, CodingKey {
        case saved
    }

    public init() {}

    public var isUp: Bool { saved != nil }

    /// The shield is wanted while On the Move is on with its shield setting, or on public Wi-Fi with that setting.
    public static func isWanted(onTheMove: Bool, moveShield: Bool, profile: NetworkProfile, publicShield: Bool) -> Bool {
        (onTheMove && moveShield) || (profile == .public && publicShield)
    }

    public func step(wanted: Bool) -> Step {
        switch (wanted, isUp) {
        case (true, false): .raise
        case (true, true): verified ? .none : .reapply
        case (false, true): .lower
        case (false, false): .none
        }
    }

    /// Records the firewall as it is now. Call before applying `shielded`, so a crash midway can still be undone.
    public mutating func willRaise(from current: FirewallState) {
        saved = current
        verified = false
    }

    /// Records the firewall as read back after applying `shielded` (nil when it couldn't be read). Shielded: done.
    /// Exactly as saved: nothing was applied, so the shield is down again and the next wanted step raises afresh.
    /// Anything else, or unreadable: partly applied, so the snapshot stays and the next wanted step reapplies.
    public mutating func didApply(observed: FirewallState?) {
        guard isUp, let observed else { return }
        if observed == Self.shielded {
            verified = true
        } else if observed == saved {
            didLower()
        }
    }

    public mutating func didLower() {
        saved = nil
        verified = false
    }

    /// Whether this Mac is shielded right now: the shield is up and the firewall, as last read, has both parts on.
    /// The user can switch the firewall off behind the shield's back, so the snapshot alone doesn't say.
    public func isOn(firewall current: FirewallState?) -> Bool {
        isUp && current == Self.shielded
    }

    /// Takes over the snapshot an older build kept in On the Move's own snapshot, so a crash under that build still
    /// gets undone. Only while the shield is down; returns whether it was taken.
    @discardableResult
    public mutating func adoptLegacy(_ legacy: FirewallState?) -> Bool {
        guard !isUp, let legacy else { return false }
        willRaise(from: legacy)
        return true
    }

    /// What to set when lowering: only the parts the shield switched on go back off. Parts that were already on
    /// stay on, and so does anything the user switched off in the meantime.
    public func restoreTarget(current: FirewallState) -> FirewallState {
        guard let saved else { return current }
        var target = current
        if !saved.enabled { target.enabled = false }
        if !saved.stealth { target.stealth = false }
        return target
    }
}
