import Foundation
import IOKit.pwr_mgt
import Darwin

public struct AwakeHolder: Equatable, Sendable {
    public let pid: Int32
    public let processName: String
    public let assertionTypes: [String]
    public let assertionNames: [String]

    public init(pid: Int32, processName: String, assertionTypes: [String], assertionNames: [String]) {
        self.pid = pid
        self.processName = processName
        self.assertionTypes = assertionTypes
        self.assertionNames = assertionNames
    }
}

public enum AwakeWatch {
    private static let sleepPreventingTypes: Set<String> = [
        "PreventUserIdleSystemSleep",
        "PreventSystemSleep",
        "NoIdleSleepAssertion",
        "PreventUserIdleDisplaySleep",
        "NoDisplaySleepAssertion"
    ]

    private static let systemDaemons: Set<String> = [
        "powerd", "WindowServer", "coreaudiod", "bluetoothd", "sharingd", "kernel", "kernel_task"
    ]

    /// macOS's own daemons live here; user-run tools like /usr/bin/caffeinate do not.
    private static let systemPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

    public static func holders(excluding pid: Int32 = getpid()) -> [AwakeHolder] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }

        var result: [AwakeHolder] = []
        for (key, assertions) in byProcess {
            let holderPID = key.int32Value
            guard holderPID != pid, holderPID > 0 else { continue }
            if let path = executablePath(holderPID), systemPathPrefixes.contains(where: path.hasPrefix) { continue }
            let name = processName(holderPID) ?? "pid \(holderPID)"
            guard !systemDaemons.contains(name) else { continue }

            var types: [String] = []
            var names: [String] = []
            for assertion in assertions {
                guard let type = assertion[kIOPMAssertionTypeKey as String] as? String,
                      sleepPreventingTypes.contains(type) else { continue }
                if !types.contains(type) { types.append(type) }
                if let assertionName = assertion[kIOPMAssertionNameKey as String] as? String,
                   !names.contains(assertionName) { names.append(assertionName) }
            }
            if !types.isEmpty {
                result.append(AwakeHolder(pid: holderPID, processName: name, assertionTypes: types, assertionNames: names))
            }
        }
        return result.sorted { $0.pid < $1.pid }
    }

    public static func appNames(
        for holders: [AwakeHolder],
        parentOf: (Int32) -> Int32? = processParent,
        nameOf: (Int32) -> String? = processName
    ) -> [String] {
        var counts: [String: Int] = [:]
        for holder in holders {
            counts[displayName(for: holder, parentOf: parentOf, nameOf: nameOf), default: 0] += 1
        }
        return counts.keys.sorted().map { name in
            let count = counts[name] ?? 1
            return count > 1 ? "\(name) (\(count))" : name
        }
    }

    private static func displayName(for holder: AwakeHolder, parentOf: (Int32) -> Int32?, nameOf: (Int32) -> String?) -> String {
        if holder.processName == "caffeinate",
           let parent = parentOf(holder.pid), let parentName = nameOf(parent), parentName == "claude" {
            return "Claude Code"
        }
        if holder.processName.hasPrefix("Google Chrome") { return "Google Chrome" }
        return holder.processName
    }

    public static func processParent(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    /// The process's name; Claude Code's native binary (named after its version, e.g. "2.1.308") reads as "claude".
    public static func processName(_ pid: Int32) -> String? {
        if let path = executablePath(pid) {
            return path.contains("/claude/versions/") ? "claude" : (path as NSString).lastPathComponent
        }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

public final class ProcessAwakeHold: @unchecked Sendable {
    public enum HoldError: Error, Equatable {
        case processNotRunning
        case assertionFailed
    }

    private let assertionManager: PowerAssertionManaging
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false
    private var onExit: (@Sendable () -> Void)?
    private var source: DispatchSourceProcess?

    public init(
        pid: Int32,
        reason: String,
        assertionManager: PowerAssertionManaging = LivePowerAssertionManager(),
        onExit: @escaping @Sendable () -> Void
    ) throws {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { throw HoldError.processNotRunning }
        self.assertionManager = assertionManager
        self.onExit = onExit

        var id: IOPMAssertionID = 0
        guard assertionManager.create(type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                      name: reason as CFString, id: &id) == kIOReturnSuccess else {
            throw HoldError.assertionFailed
        }
        assertionID = id
        isHeld = true

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in self?.processExited() }
        self.source = source
        source.resume()

        // The process may have exited between the check and the source being armed.
        if kill(pid, 0) != 0 && errno == ESRCH { processExited() }
    }

    deinit { teardown() }

    public func release() {
        _ = teardown()
    }

    private func processExited() {
        if let callback = teardown() { callback() }
    }

    @discardableResult
    private func teardown() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard isHeld else { return nil }
        isHeld = false
        assertionManager.release(id: assertionID)
        source?.cancel()
        source = nil
        let callback = onExit
        onExit = nil
        return callback
    }
}
