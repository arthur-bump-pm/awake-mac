import Foundation
import Darwin

/// A coding agent that runs in a terminal (or headless from a script).
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude, codex, gemini, qwen, opencode, crush, aider, cursor, amp, goose, droid, copilot

    /// "Claude Code", "Codex", …
    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .qwen: "Qwen Code"
        case .opencode: "OpenCode"
        case .crush: "Crush"
        case .aider: "Aider"
        case .cursor: "Cursor Agent"
        case .amp: "Amp"
        case .goose: "Goose"
        case .droid: "Droid"
        case .copilot: "Copilot CLI"
        }
    }

    /// For the panel's one line: "Claude", "Codex", "Gemini", …
    public var shortName: String {
        switch self {
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .qwen: "Qwen"
        case .cursor: "Cursor"
        case .copilot: "Copilot"
        default: displayName
        }
    }

    /// The name of its command (or script), e.g. "claude", "cursor-agent".
    static func command(_ name: String) -> AgentKind? {
        switch name {
        case "cursor-agent": .cursor
        case "cursor": nil  // the editor's CLI
        default: AgentKind(rawValue: name)
        }
    }

    /// npm packages whose script isn't named after the command.
    private static let packages: [(String, AgentKind)] = [
        ("@anthropic-ai/claude-code", .claude), ("@openai/codex", .codex), ("@google/gemini-cli", .gemini),
        ("@qwen-code/", .qwen), ("@github/copilot", .copilot), ("@sourcegraph/amp", .amp)
    ]

    static func package(inScript path: String) -> AgentKind? {
        packages.first { path.contains($0.0) }?.1
    }
}

/// One process, as the scan reads it.
public struct AgentProcess: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: uid_t
    /// The short name (`proc_name` / `pbi_comm`).
    public var name: String
    public var path: String?
    /// argv, read only for processes that could be an agent; empty otherwise.
    public var args: [String]
    /// Suspended (Ctrl-Z) or a zombie: open, but not working.
    public var stopped: Bool

    public init(pid: Int32, ppid: Int32, uid: uid_t = 501, name: String, path: String? = nil, args: [String] = [],
                stopped: Bool = false) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.path = path
        self.args = args
        self.stopped = stopped
    }

    var executableName: String { path.map { ($0 as NSString).lastPathComponent } ?? name }
}

/// What a Codex process's open session file (`~/.codex/sessions/…/rollout-*.jsonl`) says.
public enum CodexTask: Sendable, Equatable {
    /// No session file open: the TUI before its first prompt, an idle app server, or an `--ephemeral` run.
    case noSessionFile
    case idle
    case working
}

/// One coding session. Wrappers and nested agents normally fold into the top-most agent process; Codex app-server
/// sessions share that process's PID and are counted separately for each open rollout file.
public struct AgentSession: Sendable, Equatable {
    public var pid: Int32
    public var kind: AgentKind
    public var working: Bool

    public init(pid: Int32, kind: AgentKind, working: Bool) {
        self.pid = pid
        self.kind = kind
        self.working = working
    }
}

/// One agent's sessions in the status, named by strings so an agent a newer app knows never breaks an older reader.
public struct AgentSessionStatus: Codable, Sendable, Equatable {
    /// "claude", "codex", …
    public var agent: String
    /// "Claude Code", "Codex", …
    public var name: String
    public var open: Int
    public var working: Int

    public init(_ count: AgentSessionCount) {
        agent = count.agent.rawValue
        name = count.agent.displayName
        open = count.open
        working = count.working
    }
}

/// Sessions of one agent, for the panel and the status.
public struct AgentSessionCount: Sendable, Equatable {
    public var agent: AgentKind
    public var open: Int
    public var working: Int

    public init(agent: AgentKind, open: Int, working: Int) {
        self.agent = agent
        self.open = open
        self.working = working
    }

    /// Per agent, in `AgentKind` order.
    public static func tally(_ sessions: [AgentSession]) -> [AgentSessionCount] {
        AgentKind.allCases.compactMap { kind in
            let mine = sessions.filter { $0.kind == kind }
            return mine.isEmpty ? nil : AgentSessionCount(agent: kind, open: mine.count,
                                                          working: mine.filter(\.working).count)
        }
    }

    /// The panel's words, short enough for its header line, e.g. "1 Codex session working",
    /// "3 working: 2 Claude, 1 Codex", "5 sessions working" (three agents or more); nil when nothing works.
    public static func panelText(_ counts: [AgentSessionCount]) -> String? {
        let busy = counts.filter { $0.working > 0 }
        let working = busy.reduce(0) { $0 + $1.working }
        guard working > 0 else { return nil }
        let noun = working == 1 ? "session" : "sessions"
        if busy.count == 1 { return "\(working) \(busy[0].agent.shortName) \(noun) working" }
        if busy.count > 2 { return "\(working) sessions working" }
        return "\(working) working: " + busy.map { "\($0.working) \($0.agent.shortName)" }.joined(separator: ", ")
    }

    /// A sentence for the status, e.g. "2 of 3 coding sessions are working: 1 Claude Code, 1 Codex."; nil when none
    /// is open.
    public static func statusSentence(_ counts: [AgentSessionCount]) -> String? {
        let open = counts.reduce(0) { $0 + $1.open }
        let working = counts.reduce(0) { $0 + $1.working }
        guard open > 0 else { return nil }
        let noun = open == 1 ? "coding session" : "coding sessions"
        if working == 0 {
            let names = counts.map { "\($0.open) \($0.agent.displayName)" }.joined(separator: ", ")
            return open == 1 ? "1 coding session is open (\(names)), not working."
                             : "\(open) coding sessions are open (\(names)), none working."
        }
        let names = counts.filter { $0.working > 0 }.map { "\($0.working) \($0.agent.displayName)" }
            .joined(separator: ", ")
        let verb = working == 1 ? "is" : "are"
        return working == open ? "\(open) \(noun) \(verb) working: \(names)."
                               : "\(working) of \(open) \(noun) \(verb) working: \(names)."
    }
}

/// Finds coding sessions in a process list (pure; `AgentScanner` reads the live one).
public enum AgentSessions {
    private static let interpreters: Set<String> = ["node", "bun", "deno"]

    /// Which agent a process runs, if any.
    public static func kind(of process: AgentProcess) -> AgentKind? {
        if let path = process.path, path.contains("/claude/versions/") || path.hasSuffix("/native-binary/claude") {
            return .claude
        }
        let exe = process.executableName
        if let kind = AgentKind.command(exe) {
            // Native tools that share an agent's name (AWS Copilot CLI, the goose migration tool, …). Copilot CLI and
            // Amp run on node; Goose's sessions start with a subcommand.
            switch kind {
            case .copilot, .amp: return nil
            case .goose: return ["session", "s", "run", "web"].contains(subcommand(.goose, args: commandArgs(of: process)) ?? "")
                ? .goose : nil
            default: return kind
            }
        }
        guard isInterpreter(exe), let script = script(of: process) else { return nil }
        return AgentKind.package(inScript: script) ?? AgentKind.command((script as NSString).lastPathComponent)
    }

    /// Interpreter options that take the next argument as their value (`node -r hook.js`, `python -X utf8`).
    private static let interpreterValueOptions: Set<String> = [
        "-r", "--require", "--import", "--loader", "--experimental-loader", "--env-file", "-C", "--conditions",
        "--title", "-X", "-W"
    ]

    /// Where the script is in argv: the first argument that isn't an option or its value; `python -m aider` runs the
    /// module.
    private static func scriptIndex(in args: [String]) -> Int? {
        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "-m" { return index + 1 < args.count ? index + 1 : nil }
            if arg.hasPrefix("-") {
                index += interpreterValueOptions.contains(arg) ? 2 : 1
                continue
            }
            return index
        }
        return nil
    }

    static func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name) || name.hasPrefix("python") || name.hasPrefix("Python")
    }

    /// The script an interpreter runs.
    static func script(of process: AgentProcess) -> String? {
        scriptIndex(in: process.args).map { process.args[$0] }
    }

    /// The agent's own arguments (after the program, and after the script for an interpreter).
    static func commandArgs(of process: AgentProcess) -> [String] {
        guard isInterpreter(process.executableName) else { return Array(process.args.dropFirst()) }
        guard let index = scriptIndex(in: process.args) else { return [] }
        return Array(process.args[(index + 1)...])
    }

    /// Options that take the next argument as their value, so `-c key=value app-server` reads as "app-server".
    private static func valueOptions(_ kind: AgentKind) -> Set<String> {
        switch kind {
        case .codex:
            ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval",
             "-C", "--cd", "-i", "--image", "--enable", "--disable", "--add-dir", "--local-provider"]
        case .claude:
            ["--model", "--settings", "--mcp-config", "--add-dir", "--permission-mode", "--allowedTools",
             "--allowed-tools", "--disallowedTools", "--disallowed-tools", "--append-system-prompt", "--system-prompt",
             "--output-format", "--input-format", "--session-id", "--fallback-model", "--agents", "--setting-sources",
             "--plugin-dir", "--max-turns", "--debug-file"]
        default:
            ["-m", "--model", "-p", "--prompt"]
        }
    }

    /// The subcommand: the first argument that isn't an option or an option's value.
    static func subcommand(_ kind: AgentKind, args: [String]) -> String? {
        let takesValue = valueOptions(kind)
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if arg.hasPrefix("-") {
                skipNext = !arg.contains("=") && takesValue.contains(arg)
                continue
            }
            return arg
        }
        return nil
    }

    /// Commands that run the agent's binary without being a session: MCP servers, the Chrome bridge, setup.
    static func isHelper(_ kind: AgentKind, args: [String]) -> Bool {
        if args.contains("--chrome-native-host") || args.contains("--version") || args.contains("--help") { return true }
        guard let first = subcommand(kind, args: args) else { return false }
        let common: Set<String> = ["mcp", "mcp-server", "login", "logout", "completion", "update", "upgrade", "doctor",
                                   "install", "config", "auth"]
        if common.contains(first) { return true }
        switch kind {
        case .claude: return ["setup-token", "plugin", "migrate-installer"].contains(first)
        case .codex: return ["features", "apply", "sandbox", "debug"].contains(first)
        default: return false
        }
    }

    /// The session's tree as a whole works: a `caffeinate` child (Claude Code holds one while it works), a Codex
    /// task in progress, a headless run (`claude -p`, `codex exec`) still going, or — for agents with neither — CPU.
    public static func sessions(
        in processes: [AgentProcess],
        uid: uid_t = getuid(),
        codexTask: (Int32) -> CodexTask,
        codexFiles: ((Int32) -> [String: CodexTask])? = nil,
        busy: ([Int32]) -> Bool
    ) -> [AgentSession] {
        var byPID: [Int32: AgentProcess] = [:]
        var children: [Int32: [Int32]] = [:]
        for process in processes {
            byPID[process.pid] = process
            children[process.ppid, default: []].append(process.pid)
        }
        var kinds: [Int32: AgentKind] = [:]
        for process in processes where process.uid == uid {
            guard let kind = kind(of: process), !isHelper(kind, args: commandArgs(of: process)) else { continue }
            kinds[process.pid] = kind
        }

        // The top-most agent above (or at) each agent process.
        func root(of pid: Int32) -> Int32 {
            var top = pid
            var current = byPID[pid]?.ppid ?? 0
            var steps = 0
            while current > 1, steps < 128, let process = byPID[current] {
                if kinds[current] != nil { top = current }
                current = process.ppid
                steps += 1
            }
            return top
        }
        var members: [Int32: [Int32]] = [:]
        for pid in kinds.keys { members[root(of: pid), default: []].append(pid) }

        func descendants(of pid: Int32) -> [Int32] {
            var result = [pid]
            var index = 0
            while index < result.count, result.count < 4096 {
                result += children[result[index]] ?? []
                index += 1
            }
            return result
        }
        func memberWorks(_ pid: Int32) -> Bool {
            guard let process = byPID[pid], let kind = kinds[pid], !process.stopped else { return false }
            if (children[pid] ?? []).contains(where: { byPID[$0]?.name == "caffeinate" && byPID[$0]?.stopped == false }) {
                return true
            }
            let args = commandArgs(of: process)
            switch kind {
            case .claude:
                let headless = args.contains("-p") || args.contains("--print")
                let streaming = zip(args, args.dropFirst()).contains { $0 == "--input-format" && $1 == "stream-json" }
                    || args.contains("--input-format=stream-json")
                return headless && !streaming
            case .codex:
                switch codexTask(pid) {
                case .working: return true
                case .idle: return false
                case .noSessionFile: return ["exec", "e", "review"].contains(subcommand(.codex, args: args) ?? "")
                }
            default:
                return busy(descendants(of: pid))
            }
        }

        var result: [AgentSession] = []
        for (rootPID, pids) in members {
            guard let process = byPID[rootPID], let kind = kinds[rootPID] else { continue }
            if kind == .codex, subcommand(.codex, args: commandArgs(of: process)) == "app-server",
               let codexFiles {
                var files: [String: Bool] = [:]
                var serverPIDs: Set<Int32> = []
                for pid in pids where kinds[pid] == .codex {
                    guard let member = byPID[pid],
                          subcommand(.codex, args: commandArgs(of: member)) == "app-server" else { continue }
                    serverPIDs.insert(pid)
                    for (path, task) in codexFiles(pid) {
                        let working = task == .working && byPID[pid]?.stopped == false
                        files[path, default: false] = files[path, default: false] || working
                    }
                }
                // Sample all members even when the server has no open files. Nested work cannot be
                // attributed to a particular rollout, so mark one idle file only if none already works.
                let nestedWorks = pids.map { (pid: $0, working: memberWorks($0)) }
                    .contains { !serverPIDs.contains($0.pid) && $0.working }
                if nestedWorks, !files.values.contains(true), let first = files.keys.sorted().first {
                    files[first] = true
                }
                for path in files.keys.sorted() {
                    result.append(AgentSession(pid: rootPID, kind: kind,
                                               working: !process.stopped && files[path] == true))
                }
                continue
            }
            // An app server (Codex in an editor or the ChatGPT app) is a session only while it has one open; behind a
            // node shim the native child holds the file.
            if kind == .codex, subcommand(.codex, args: commandArgs(of: process)) == "app-server",
               pids.allSatisfy({ kinds[$0] != .codex || codexTask($0) == .noSessionFile }) {
                continue
            }
            // Every member is asked (no short cut), so CPU baselines stay fresh.
            let works = pids.map(memberWorks)
            let working = !process.stopped && works.contains(true)
            result.append(AgentSession(pid: rootPID, kind: kind, working: working))
        }
        return result.sorted { $0.pid < $1.pid }
    }

    /// The last task event in the tail of a Codex session file: `task_started` until `task_complete` or
    /// `turn_aborted`. A tail with neither belongs to a long turn when the file is bigger than the tail.
    public static func codexTask(tail: String, fileIsLarger: Bool) -> CodexTask {
        let started = tail.range(of: "\"type\":\"task_started\"", options: .backwards)?.lowerBound
        let ended = [tail.range(of: "\"type\":\"task_complete\"", options: .backwards)?.lowerBound,
                     tail.range(of: "\"type\":\"turn_aborted\"", options: .backwards)?.lowerBound].compactMap { $0 }.max()
        switch (started, ended) {
        case let (start?, end?): return start > end ? .working : .idle
        case (_?, nil): return .working
        case (nil, _?): return .idle
        case (nil, nil): return fileIsLarger ? .working : .idle
        }
    }
}

/// Reads the live process list. Keeps CPU times between scans for agents without a better signal, and caches each
/// Codex session file's state by size and modification time.
public final class AgentScanner: @unchecked Sendable {
    /// Average share of one core over the last scan that counts as working, for agents without a better signal.
    static let busyCores = 0.05
    private static let tailBytes = 256 * 1024

    private let lock = NSLock()
    /// Per process: its start (to notice a reused pid), CPU time and when it was read. Kept until the process is gone.
    private var cpuSamples: [Int32: (start: UInt64, cpu: UInt64, at: Date)] = [:]
    private var codexFiles: [String: (size: Int64, modified: Date, task: CodexTask)] = [:]
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public init() {}

    public struct Result: Sendable, Equatable {
        public var sessions: [AgentSession]
        /// Every agent process (sessions and the agents inside them), to tell their `caffeinate`s from others'.
        public var agentPIDs: Set<Int32>
    }

    public func scan(now: Date = .now) -> Result {
        return scan(processes: Self.allProcesses(), uid: getuid(), now: now, usage: usage(_:),
                    codexFiles: codexTasks(pid:))
    }

    // Internal injection keeps the same sampling and session logic testable without reading live processes.
    func scan(processes: [AgentProcess], uid: uid_t, now: Date,
              usage: (Int32) -> (start: UInt64, cpu: UInt64, age: TimeInterval)?,
              codexFiles: @escaping (Int32) -> [String: CodexTask]) -> Result {
        lock.lock()
        defer { lock.unlock() }
        var filesByPID: [Int32: [String: CodexTask]] = [:]
        let filesForPID: (Int32) -> [String: CodexTask] = { pid in
            if let files = filesByPID[pid] { return files }
            let files = codexFiles(pid)
            filesByPID[pid] = files
            return files
        }
        let sessions = AgentSessions.sessions(in: processes, uid: uid, codexTask: { pid in
            let tasks = filesForPID(pid).values
            return tasks.isEmpty ? .noSessionFile : (tasks.contains(.working) ? .working : .idle)
        }, codexFiles: filesForPID) { pids in
            // `pids` is the agent process, then its descendants.
            var cores = 0.0
            for pid in pids {
                guard let usage = usage(pid) else { continue }
                defer { self.cpuSamples[pid] = (usage.start, usage.cpu, now) }
                if let last = self.cpuSamples[pid], last.start == usage.start, now > last.at {
                    cores += Double(usage.cpu &- min(usage.cpu, last.cpu)) / 1e9 / now.timeIntervalSince(last.at)
                } else {
                    cores += Double(usage.cpu) / 1e9 / max(usage.age, 1)  // first read: its average so far
                }
            }
            return cores >= Self.busyCores
        }
        let alive = Set(processes.map(\.pid))
        cpuSamples = cpuSamples.filter { alive.contains($0.key) }
        let agentPIDs = Set(processes.filter { process in
            process.uid == uid && AgentSessions.kind(of: process) != nil
        }.map(\.pid))
        return Result(sessions: sessions, agentPIDs: agentPIDs)
    }

    // MARK: - Live reads

    static func allProcesses() -> [AgentProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        let uid = getuid()
        return pids.prefix(Int(written)).compactMap { pid -> AgentProcess? in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            let name = withUnsafeBytes(of: info.pbi_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            var process = AgentProcess(pid: pid, ppid: Int32(info.pbi_ppid), uid: info.pbi_uid, name: name,
                                       stopped: info.pbi_status == UInt32(SSTOP) || info.pbi_status == UInt32(SZOMB))
            guard info.pbi_uid == uid else { return process }
            process.path = AwakeWatch.executablePath(pid)
            let exe = process.executableName
            let candidate = AgentKind.command(exe) != nil || AgentSessions.isInterpreter(exe)
                || (process.path.map { $0.contains("/claude/") } ?? false)
            if candidate { process.args = arguments(pid) }
            return process
        }
    }

    /// argv through `KERN_PROCARGS2` (own processes only).
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }  // the executable path
        while index < size, buffer[index] == 0 { index += 1 }  // its padding
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    /// The process's start (mach time), CPU time plus that of its children it has waited for (ns), and age (s).
    private func usage(_ pid: Int32) -> (start: UInt64, cpu: UInt64, age: TimeInterval)? {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0
            }
        }
        guard ok else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time &+ info.ri_child_user_time &+ info.ri_child_system_time
        let age = nanoseconds(mach_absolute_time() &- min(mach_absolute_time(), info.ri_proc_start_abstime))
        return (info.ri_proc_start_abstime, nanoseconds(ticks), Double(age) / 1e9)
    }

    private func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue / UInt64(max(timebase.denom, 1))
    }

    /// The Codex task state over every session file the process has open.
    private func codexTasks(pid: Int32) -> [String: CodexTask] {
        let files = Self.openFiles(pid).filter { path in
            let name = (path as NSString).lastPathComponent
            return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") && path.contains("/sessions/")
        }
        var tasks: [String: CodexTask] = [:]
        for path in files { tasks[(path as NSString).standardizingPath] = task(ofFile: path) }
        return tasks
    }

    private func task(ofFile path: String) -> CodexTask {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return .idle }
        if let cached = codexFiles[path], cached.size == size, cached.modified == modified { return cached.task }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .idle }
        defer { try? handle.close() }
        let offset = max(0, size - Int64(Self.tailBytes))
        try? handle.seek(toOffset: UInt64(offset))
        let data = (try? handle.readToEnd()) ?? Data()
        let task = AgentSessions.codexTask(tail: String(decoding: data, as: UTF8.self), fileIsLarger: offset > 0)
        if codexFiles.count > 64 { codexFiles.removeAll() }
        codexFiles[path] = (size, modified, task)
        return task
    }

    /// Paths of the files a process has open (own processes only).
    static func openFiles(_ pid: Int32) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard written > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(written) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }
}
