import CoreGraphics
import Foundation
import IOKit.ps

public struct DeskState: Equatable, Sendable {
    public var externalDisplay: Bool
    public var onPower: Bool

    public init(externalDisplay: Bool, onPower: Bool) {
        self.externalDisplay = externalDisplay
        self.onPower = onPower
    }

    public var atDesk: Bool { externalDisplay && onPower }

    public static func current() -> DeskState {
        DeskState(externalDisplay: hasExternalDisplay(), onPower: !PowerSource.isOnBattery())
    }

    private static func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

public enum DeskEvent: Equatable, Sendable {
    case arrived, left
}

/// Turns raw desk observations into arrived/left events. A change is reported only once it has held for
/// `holdTime`, so a flapping cable or a brief power blip does not fire anything.
public struct DeskDetector: Sendable {
    static let holdTime: TimeInterval = 5

    private var confirmed: Bool?
    private var pending: (atDesk: Bool, since: Date)?

    public init() {}

    public mutating func update(_ state: DeskState, now: Date) -> DeskEvent? {
        let atDesk = state.atDesk
        guard let confirmed else {
            self.confirmed = atDesk
            return nil
        }
        guard atDesk != confirmed else {
            pending = nil
            return nil
        }
        guard let pending, pending.atDesk == atDesk else {
            pending = (atDesk, now)
            return nil
        }
        guard now.timeIntervalSince(pending.since) >= Self.holdTime else { return nil }
        self.confirmed = atDesk
        self.pending = nil
        return atDesk ? .arrived : .left
    }
}
