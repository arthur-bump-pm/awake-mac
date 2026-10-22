import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake with an IOPM assertion, indefinitely or for a set time.
/// Adapted from Insomnia's SleepManager.
@MainActor
public final class KeepAwakeController: ObservableObject {
    @Published public private(set) var isActive = false
    /// Seconds left in a timed session; nil when inactive or indefinite.
    @Published public private(set) var remainingTime: TimeInterval?
    /// The length the current session was started with; nil when inactive or indefinite.
    @Published public private(set) var activatedDuration: TimeInterval?
    /// When true the display may sleep while the system stays awake.
    @Published public var allowDisplaySleep: Bool {
        didSet {
            guard isActive, oldValue != allowDisplaySleep else { return }
            // Rebuild the assertion with the new type, keeping the time left.
            let remaining = remainingTime
            let duration = activatedDuration
            releaseAssertion()
            createAssertion(remaining: remaining, duration: duration)
        }
    }

    private let assertionManager: PowerAssertionManaging
    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private var endDate: Date?
    private let reason = "Outpost - Keep Awake" as CFString

    public init(assertionManager: PowerAssertionManaging = LivePowerAssertionManager(), allowDisplaySleep: Bool = false) {
        self.assertionManager = assertionManager
        self.allowDisplaySleep = allowDisplaySleep
    }

    public func activate(for duration: TimeInterval? = nil) {
        if isActive {
            deactivate()
        }
        createAssertion(remaining: duration, duration: duration)
    }

    public func deactivate() {
        releaseAssertion()
        remainingTime = nil
        activatedDuration = nil
    }

    private var assertionType: CFString {
        (allowDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypeNoDisplaySleep) as CFString
    }

    private func createAssertion(remaining: TimeInterval?, duration: TimeInterval?) {
        guard assertionManager.create(type: assertionType, name: reason, id: &assertionID) == kIOReturnSuccess else {
            isActive = false
            return
        }
        isActive = true
        activatedDuration = duration
        remainingTime = remaining
        endDate = remaining.map { Date().addingTimeInterval($0) }
        guard endDate != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func releaseAssertion() {
        timer?.invalidate()
        timer = nil
        endDate = nil
        if isActive {
            assertionManager.release(id: assertionID)
            isActive = false
        }
    }

    private func tick() {
        guard let endDate else { return }
        let left = endDate.timeIntervalSinceNow
        if left <= 0 {
            deactivate()
        } else {
            remainingTime = left.rounded(.up)
        }
    }
}
