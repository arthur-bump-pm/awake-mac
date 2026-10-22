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
    public init() {}

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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
