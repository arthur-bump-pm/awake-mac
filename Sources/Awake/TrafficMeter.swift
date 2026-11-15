import AwakeCore
import Foundation

/// The panel footer's live traffic: reads the counters once a second while the panel is open, nothing while it's
/// closed. Kept apart from `AppModel`, so a new reading redraws only the footer, not the menu bar glyph.
@MainActor
final class TrafficMeter: ObservableObject {
    @Published private(set) var rate: TrafficRate?

    /// The rate covers the last two seconds (three reads), which steadies it without lagging much.
    static let window = 3
    private let read: () -> TrafficCounters?
    private var reads: [(time: Date, counters: TrafficCounters)] = []
    private var timer: Timer?

    init(read: @escaping () -> TrafficCounters? = TrafficReader.read) {
        self.read = read
    }

    /// A fixed reading for `--render-preview`; it never reads the system.
    static func preview(_ rate: TrafficRate) -> TrafficMeter {
        let meter = TrafficMeter(read: { nil })
        meter.rate = rate
        return meter
    }

    func start() {
        guard timer == nil else { return }
        reads = []
        rate = nil
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard let counters = read() else { return }
        reads.append((Date(), counters))
        if reads.count > Self.window { reads.removeFirst(reads.count - Self.window) }
        if let first = reads.first, let last = reads.last, reads.count > 1 {
            rate = TrafficRate.between(first.counters, at: first.time, last.counters, at: last.time)
        }
    }
}
