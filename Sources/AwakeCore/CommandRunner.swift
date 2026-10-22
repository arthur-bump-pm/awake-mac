import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public protocol CommandRunning: Sendable {
    @discardableResult
    func run(_ executable: String, _ arguments: [String]) -> CommandResult
}

/// Runs a command synchronously and returns its exit status with stdout and stderr combined.
public struct ProcessCommandRunner: CommandRunning {
    /// Stops the command after this many seconds (for tools that can hang); nil waits for it to finish.
    private let timeout: TimeInterval?

    public init(timeout: TimeInterval? = nil) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
        let watchdog = timeout.map { seconds in
            let item = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog?.cancel()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// Runs blocking work (shell commands) one item at a time, in order, on its own serial queue. `close` waits for the
/// item in flight and everything queued before it, runs one last item, and turns away anything queued after: for an
/// exit that must not race a command that is still running.
public final class SerialCommandQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    /// Only touched on `queue`.
    private var closed = false

    public init(label: String) {
        queue = DispatchQueue(label: label)
    }

    /// Runs `work` after everything queued before it. Nil, without running it, once the queue is closed.
    public func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.closed ? nil : work())
            }
        }
    }

    /// Blocks until the work in flight and everything queued before it is done, then runs `last` and closes the
    /// queue. Closing again just runs `last`.
    public func close<T>(then last: () throws -> T) rethrows -> T {
        try queue.sync {
            closed = true
            return try last()
        }
    }
}
