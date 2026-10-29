import Foundation

/// When an Overnight session ends.
public enum OvernightEnd: String, Codable, CaseIterable, Sendable {
    /// At the morning hour chosen in Settings.
    case morning
    /// A few minutes after every Claude session has gone idle (see `AppModel.claudeIdleGrace`).
    case whenClaudeFinishes
    case manually
}

/// One Overnight session: the Mac keeps running with the lid open or closed (lid-closed mode, nothing else changed)
/// until its end. Pure, so the end can be tested with fixed dates.
public struct OvernightSession: Codable, Equatable, Sendable {
    /// The morning hours offered in Settings, and the default.
    public static let morningChoices = [7, 8, 9, 10]
    public static let defaultMorningHour = 9
    /// A session never ends sooner than this at the morning hour: started at 8:30 with a 9 AM end, it runs to 9 AM
    /// tomorrow, not for half an hour.
    public static let minimumMorningRun: TimeInterval = 3600

    public var end: OvernightEnd
    /// For `.morning`: when it ends.
    public var until: Date?
    /// When it started, so a session started again with the same end isn't equal to the one before (a queued end of
    /// the old one must not end the new one).
    public var started: Date

    public init(end: OvernightEnd, until: Date?, started: Date) {
        self.end = end
        self.until = until
        self.started = started
    }

    public static func start(end: OvernightEnd, morningHour: Int, now: Date,
                             calendar: Calendar = .current) -> OvernightSession {
        OvernightSession(end: end, until: end == .morning ? nextMorning(hour: morningHour, after: now, calendar: calendar) : nil,
                         started: now)
    }

    /// The first `hour`:00 at least `minimumMorningRun` after `now`.
    public static func nextMorning(hour: Int, after now: Date, calendar: Calendar = .current) -> Date {
        let earliest = now.addingTimeInterval(minimumMorningRun)
        let components = DateComponents(hour: hour, minute: 0, second: 0)
        return calendar.nextDate(after: earliest, matching: components, matchingPolicy: .nextTime)
            ?? earliest.addingTimeInterval(24 * 3600)
    }

    /// `claudeFinished`: every Claude session has been idle long enough, after at least one worked.
    public func isOver(now: Date, claudeFinished: Bool) -> Bool {
        switch end {
        case .morning: until.map { now >= $0 } ?? false
        case .whenClaudeFinishes: claudeFinished
        case .manually: false
        }
    }
}
