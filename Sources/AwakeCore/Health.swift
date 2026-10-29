import Darwin
import Foundation

/// The CPU's cumulative tick counters, summed over every core (`host_statistics` HOST_CPU_LOAD_INFO). They're 32-bit
/// and wrap after weeks, so differences use wrapping arithmetic.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// The share of time the CPU was busy since `earlier` (0…1, over all cores), or nil when no time passed.
    public func busyFraction(since earlier: CPUTicks) -> Double? {
        let busy = Double(user &- earlier.user) + Double(system &- earlier.system) + Double(nice &- earlier.nice)
        let total = busy + Double(idle &- earlier.idle)
        return total > 0 ? busy / total : nil
    }
}

/// macOS's memory pressure level (`kern.memorystatus_vm_pressure_level`): what Activity Monitor's graph colors.
public enum MemoryPressure: Int, Comparable, Codable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool { lhs.rawValue < rhs.rawValue }

    public var name: String {
        switch self {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }
}

/// One look at the Mac's health. Nil fields weren't read this time (the disk is read less often).
public struct HealthSample: Sendable {
    public var cpu: CPUTicks?
    public var memory: MemoryPressure?
    /// Free space on the startup disk for important use (what Finder shows, purgeable space included).
    public var diskFreeBytes: Int64?
    /// On battery, or on a charger too weak to keep up.
    public var discharging: Bool

    public init(cpu: CPUTicks?, memory: MemoryPressure?, diskFreeBytes: Int64?, discharging: Bool) {
        self.cpu = cpu
        self.memory = memory
        self.diskFreeBytes = diskFreeBytes
        self.discharging = discharging
    }
}

/// Something about the Mac's health that can stop work from finishing.
public enum HealthWarning: Equatable, Sendable {
    /// The startup disk is nearly full: builds, downloads and logs can fail.
    case diskAlmostFull(freeBytes: Int64)
    /// Memory pressure stayed at warning or critical: apps slow down, and macOS may quit some.
    case lowMemory(critical: Bool)
    /// On battery, the CPU averaged at least `HealthWatch.busyCores` busy cores over `HealthWatch.cpuWindow`.
    case busyCPU

    public enum Kind: String, Sendable {
        case disk, memory, cpu
    }

    public var kind: Kind {
        switch self {
        case .diskAlmostFull: .disk
        case .lowMemory: .memory
        case .busyCPU: .cpu
        }
    }
}

/// Decides the health warnings from samples taken every few seconds. Pure: every input, the time included, is passed
/// in. `warnings` is what's wrong now (for the panel); `observe` returns the warnings to notify about, at most one per
/// episode.
public struct HealthWatch: Sendable {
    /// Under this much free space the disk counts as almost full; it stops counting only above `diskClearBytes`, so
    /// a disk hovering at the line doesn't flicker.
    public static let diskWarnBytes: Int64 = 10_000_000_000
    public static let diskClearBytes: Int64 = 12_000_000_000
    /// Memory pressure must stay up this long: short spikes are normal.
    public static let memoryHold: TimeInterval = 60
    /// At most one low-memory notification this often.
    public static let memoryNoticeInterval: TimeInterval = 3600
    /// The CPU warning: at least this many cores busy on average over `cpuWindow`, all of it on battery…
    public static let busyCores = 1.0
    public static let cpuWindow: TimeInterval = 600
    /// …and it clears once the last `calmWindow` averages under `calmCores`, or the Mac is plugged in.
    public static let calmCores = 0.5
    public static let calmWindow: TimeInterval = 60

    public let cores: Int
    public private(set) var warnings: [HealthWarning] = []
    /// Busy cores on average over about the last minute, for the status; nil until there's a minute of samples.
    public private(set) var recentBusyCores: Double?
    public private(set) var diskFreeBytes: Int64?
    public private(set) var memory: MemoryPressure?

    private var cpuSamples: [(at: Date, ticks: CPUTicks)] = []
    private var dischargingSince: Date?
    private var memoryHighSince: Date?
    private var lastMemoryNotice: Date?
    private var cpuNotified = false

    public init(cores: Int) {
        self.cores = max(cores, 1)
    }

    public mutating func observe(_ sample: HealthSample, now: Date) -> [HealthWarning] {
        let before = warnings
        if let free = sample.diskFreeBytes { diskFreeBytes = free }
        if let pressure = sample.memory { memory = pressure }
        if let ticks = sample.cpu {
            cpuSamples.append((now, ticks))
            cpuSamples.removeAll { now.timeIntervalSince($0.at) > Self.cpuWindow + 60 }
        }
        recentBusyCores = busyCores(over: Self.calmWindow, now: now)

        var next: [HealthWarning] = []
        if let free = diskFreeBytes {
            let wasFull = before.contains { $0.kind == .disk }
            if free < Self.diskWarnBytes || (wasFull && free <= Self.diskClearBytes) {
                next.append(.diskAlmostFull(freeBytes: free))
            }
        }

        if let memory, memory >= .warning {
            let since = memoryHighSince ?? now
            memoryHighSince = since
            if now.timeIntervalSince(since) >= Self.memoryHold {
                next.append(.lowMemory(critical: memory == .critical))
            }
        } else {
            memoryHighSince = nil
        }

        if sample.discharging {
            let since = dischargingSince ?? now
            dischargingSince = since
            let wasBusy = before.contains { $0.kind == .cpu }
            if wasBusy {
                if (recentBusyCores ?? 0) >= Self.calmCores { next.append(.busyCPU) }
            } else if now.timeIntervalSince(since) >= Self.cpuWindow, (recentBusyCores ?? 0) >= Self.calmCores,
                      let average = busyCores(over: Self.cpuWindow, now: now), average >= Self.busyCores {
                next.append(.busyCPU)
            }
        } else {
            dischargingSince = nil
            cpuNotified = false
        }

        warnings = next
        return next.filter { warning in
            switch warning {
            case .diskAlmostFull:
                return !before.contains { $0.kind == .disk }
            case .lowMemory:
                guard !before.contains(where: { $0.kind == .memory }) else { return false }
                guard lastMemoryNotice.map({ now.timeIntervalSince($0) >= Self.memoryNoticeInterval }) ?? true else {
                    return false
                }
                lastMemoryNotice = now
                return true
            case .busyCPU:
                guard !cpuNotified else { return false }
                cpuNotified = true
                return true
            }
        }
    }

    /// Busy cores on average from the newest sample at least `span` old to the latest one; nil without such a sample.
    private func busyCores(over span: TimeInterval, now: Date) -> Double? {
        guard let latest = cpuSamples.last,
              let start = cpuSamples.last(where: { now.timeIntervalSince($0.at) >= span }),
              let fraction = latest.ticks.busyFraction(since: start.ticks) else { return nil }
        return fraction * Double(cores)
    }
}

/// Live readings for `HealthWatch`. Each is cheap except the disk (a file system query), which callers run off the
/// main actor.
public enum HealthMonitor {
    private static let host = mach_host_self()

    public static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks  // indexed by CPU_STATE_USER, _SYSTEM, _IDLE, _NICE
        return CPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    public static func memoryPressure() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return MemoryPressure(rawValue: Int(level))
    }

    public static func diskFreeBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// The process using the most CPU right now, e.g. "node", from `ps` (only run when a CPU warning starts).
    public static func busiestProcess(runner: CommandRunning = ProcessCommandRunner()) -> String? {
        topProcess(inPsOutput: runner.run("/bin/ps", ["-Aceo", "pcpu=,comm=", "-r"]).output)
    }

    /// The name on the first line of `ps -Aceo pcpu=,comm= -r`, e.g. " 98.4 python" → "python".
    static func topProcess(inPsOutput output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard fields.count == 2, Double(fields[0]) != nil else { return nil }
        let name = fields[1].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
