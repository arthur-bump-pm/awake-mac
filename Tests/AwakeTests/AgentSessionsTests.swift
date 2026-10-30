import XCTest
@testable import AwakeCore

final class AgentSessionsTests: XCTestCase {
    private let claudePath = "/Users/someone/.local/share/claude/versions/2.1.314"

    private func scan(_ processes: [AgentProcess], codex: [Int32: CodexTask] = [:],
                      busy: Set<Int32> = []) -> [AgentSession] {
        AgentSessions.sessions(in: processes, uid: 501, codexTask: { codex[$0] ?? .noSessionFile },
                               busy: { !busy.isDisjoint(with: $0) })
    }

    private func claude(_ pid: Int32, parent: Int32 = 1, args: [String] = ["claude"]) -> AgentProcess {
        AgentProcess(pid: pid, ppid: parent, name: "2.1.314", path: claudePath, args: args)
    }

    private func caffeinate(_ pid: Int32, parent: Int32) -> AgentProcess {
        AgentProcess(pid: pid, ppid: parent, name: "caffeinate", path: "/usr/bin/caffeinate")
    }

    func testOneSessionPerClaudeProcessWorkingByCaffeinate() {
        let sessions = scan([claude(10), caffeinate(11, parent: 10), claude(20), claude(30), caffeinate(31, parent: 30)])
        XCTAssertEqual(sessions, [AgentSession(pid: 10, kind: .claude, working: true),
                                  AgentSession(pid: 20, kind: .claude, working: false),
                                  AgentSession(pid: 30, kind: .claude, working: true)])
    }

    func testHelpersAreNotSessions() {
        let processes = [
            claude(10, args: ["claude", "--chrome-native-host"]),
            claude(11, args: ["claude", "mcp", "serve"]),
            AgentProcess(pid: 12, ppid: 1, name: "codex", path: "/x/bin/codex", args: ["codex", "mcp-server"]),
            AgentProcess(pid: 13, ppid: 1, name: "codex", path: "/x/bin/codex", args: ["codex", "-c", "a=b", "login"])
        ]
        XCTAssertEqual(scan(processes), [])
    }

    func testOtherUsersAndNonAgentsIgnored() {
        let processes = [
            AgentProcess(pid: 10, ppid: 1, uid: 0, name: "claude", path: "/usr/local/bin/claude", args: ["claude"]),
            AgentProcess(pid: 11, ppid: 1, name: "node", path: "/opt/homebrew/bin/node", args: ["node", "server.js"]),
            AgentProcess(pid: 12, ppid: 1, name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor")
        ]
        XCTAssertEqual(scan(processes), [])
    }

    func testCodexNodeShimAndNativeBinaryAreOneSession() {
        let processes = [
            AgentProcess(pid: 10, ppid: 1, name: "node", path: "/opt/homebrew/bin/node",
                         args: ["node", "/opt/homebrew/bin/codex"]),
            AgentProcess(pid: 11, ppid: 10, name: "codex", path: "/x/vendor/aarch64-apple-darwin/bin/codex", args: ["codex"])
        ]
        XCTAssertEqual(scan(processes, codex: [11: .working]), [AgentSession(pid: 10, kind: .codex, working: true)])
        XCTAssertEqual(scan(processes, codex: [11: .idle]), [AgentSession(pid: 10, kind: .codex, working: false)])
    }

    func testCodexWorkingFollowsItsSessionFile() {
        let tui = AgentProcess(pid: 10, ppid: 1, name: "codex", path: "/x/bin/codex", args: ["codex"])
        XCTAssertEqual(scan([tui]).first?.working, false)  // before the first prompt
        XCTAssertEqual(scan([tui], codex: [10: .working]).first?.working, true)
        XCTAssertEqual(scan([tui], codex: [10: .idle]).first?.working, false)
    }

    func testHeadlessRunsWorkWhileAlive() {
        let exec = AgentProcess(pid: 10, ppid: 1, name: "codex", path: "/x/bin/codex",
                                args: ["codex", "-m", "gpt", "exec", "--ephemeral", "review this"])
        XCTAssertEqual(scan([exec]), [AgentSession(pid: 10, kind: .codex, working: true)])
        XCTAssertEqual(scan([exec], codex: [10: .idle]).first?.working, false)  // a finished turn in its file
        XCTAssertEqual(scan([claude(20, args: ["claude", "-p", "hi"])]).first?.working, true)
        // An SDK host waiting for input works only with its caffeinate.
        let host = claude(30, args: ["claude", "-p", "--input-format", "stream-json"])
        XCTAssertEqual(scan([host]).first?.working, false)
        XCTAssertEqual(scan([host, caffeinate(31, parent: 30)]).first?.working, true)
    }

    func testCodexDashPIsAProfileNotPrint() {
        let tui = AgentProcess(pid: 10, ppid: 1, name: "codex", path: "/x/bin/codex", args: ["codex", "-p", "work", "exec"])
        XCTAssertEqual(scan([tui]).first?.working, true)
    }

    func testAgentsStartedInsideASessionFoldIntoIt() {
        let processes = [
            claude(10), caffeinate(11, parent: 10),
            AgentProcess(pid: 12, ppid: 10, name: "zsh", path: "/bin/zsh"),
            AgentProcess(pid: 13, ppid: 12, name: "codex", path: "/x/bin/codex", args: ["codex", "exec", "review"]),
            claude(14, parent: 12, args: ["claude", "-p", "subtask"])
        ]
        XCTAssertEqual(scan(processes), [AgentSession(pid: 10, kind: .claude, working: true)])
        // The nested run keeps the session working even between the parent's own keep-awakes.
        XCTAssertEqual(scan(processes.filter { $0.pid != 11 }), [AgentSession(pid: 10, kind: .claude, working: true)])
    }

    func testStoppedSessionIsOpenButNotWorking() {
        var stopped = claude(10)
        stopped.stopped = true
        XCTAssertEqual(scan([stopped, caffeinate(11, parent: 10)]), [AgentSession(pid: 10, kind: .claude, working: false)])
    }

    func testCodexAppServerCountsOnlyWithAnOpenSession() {
        let server = AgentProcess(pid: 10, ppid: 5, name: "codex", path: "/ext/bin/macos-aarch64/codex",
                                  args: ["codex", "-c", "features.x=true", "app-server", "--analytics-default-enabled"])
        XCTAssertEqual(scan([server]), [])
        XCTAssertEqual(scan([server], codex: [10: .working]), [AgentSession(pid: 10, kind: .codex, working: true)])
        XCTAssertEqual(scan([server], codex: [10: .idle]), [AgentSession(pid: 10, kind: .codex, working: false)])
    }

    func testOtherAgentsByCommandOrScriptWorkByCPU() {
        let processes = [
            AgentProcess(pid: 10, ppid: 1, name: "node", path: "/opt/homebrew/bin/node",
                         args: ["node", "--no-warnings", "/opt/homebrew/bin/gemini"]),
            AgentProcess(pid: 11, ppid: 10, name: "zsh", path: "/bin/zsh"),
            AgentProcess(pid: 20, ppid: 1, name: "Python", path: "/x/Python.app/Contents/MacOS/Python",
                         args: ["python3", "/Users/someone/.local/bin/aider"]),
            AgentProcess(pid: 30, ppid: 1, name: "opencode", path: "/x/bin/opencode", args: ["opencode"]),
            AgentProcess(pid: 40, ppid: 1, name: "node", path: "/x/node",
                         args: ["node", "/x/lib/node_modules/@anthropic-ai/claude-code/cli.js"])
        ]
        XCTAssertEqual(scan(processes, busy: [11]), [
            AgentSession(pid: 10, kind: .gemini, working: true),
            AgentSession(pid: 20, kind: .aider, working: false),
            AgentSession(pid: 30, kind: .opencode, working: false),
            AgentSession(pid: 40, kind: .claude, working: false)
        ])
    }

    func testCodexTaskFromFileTail() {
        let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        let complete = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        let aborted = #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
        XCTAssertEqual(AgentSessions.codexTask(tail: started, fileIsLarger: false), .working)
        XCTAssertEqual(AgentSessions.codexTask(tail: started + "\n" + complete, fileIsLarger: false), .idle)
        XCTAssertEqual(AgentSessions.codexTask(tail: complete + "\n" + started, fileIsLarger: false), .working)
        XCTAssertEqual(AgentSessions.codexTask(tail: started + "\n" + aborted, fileIsLarger: false), .idle)
        XCTAssertEqual(AgentSessions.codexTask(tail: "{}", fileIsLarger: false), .idle)
        XCTAssertEqual(AgentSessions.codexTask(tail: "{}", fileIsLarger: true), .working)
    }

    func testTexts() {
        let one = [AgentSessionCount(agent: .codex, open: 2, working: 1)]
        XCTAssertEqual(AgentSessionCount.panelText(one), "1 Codex session working")
        XCTAssertEqual(AgentSessionCount.statusSentence(one), "1 of 2 coding sessions is working: 1 Codex.")
        let mixed = [AgentSessionCount(agent: .claude, open: 3, working: 2), AgentSessionCount(agent: .codex, open: 1, working: 1)]
        XCTAssertEqual(AgentSessionCount.panelText(mixed), "3 working: 2 Claude, 1 Codex")
        XCTAssertEqual(AgentSessionCount.statusSentence(mixed), "3 of 4 coding sessions are working: 2 Claude Code, 1 Codex.")
        let idle = [AgentSessionCount(agent: .claude, open: 2, working: 0)]
        XCTAssertNil(AgentSessionCount.panelText(idle))
        XCTAssertEqual(AgentSessionCount.panelText([AgentSessionCount(agent: .claude, open: 2, working: 2)]),
                       "2 Claude sessions working")
        XCTAssertEqual(AgentSessionCount.statusSentence(idle), "2 coding sessions are open (2 Claude Code), none working.")
        XCTAssertNil(AgentSessionCount.statusSentence([]))
        let many = [AgentSessionCount(agent: .claude, open: 2, working: 2), AgentSessionCount(agent: .codex, open: 1, working: 1),
                    AgentSessionCount(agent: .gemini, open: 1, working: 1)]
        XCTAssertEqual(AgentSessionCount.panelText(many), "4 sessions working")
    }

    func testTallyKeepsAgentOrder() {
        let sessions = [AgentSession(pid: 3, kind: .codex, working: true), AgentSession(pid: 1, kind: .claude, working: false),
                        AgentSession(pid: 2, kind: .claude, working: true)]
        XCTAssertEqual(AgentSessionCount.tally(sessions), [AgentSessionCount(agent: .claude, open: 2, working: 1),
                                                           AgentSessionCount(agent: .codex, open: 1, working: 1)])
    }

    func testNamesHeldByOtherToolsNeedTheirAgentsShape() {
        let processes = [
            AgentProcess(pid: 10, ppid: 1, name: "copilot", path: "/opt/homebrew/bin/copilot", args: ["copilot", "deploy"]),
            AgentProcess(pid: 11, ppid: 1, name: "goose", path: "/x/go/bin/goose", args: ["goose", "postgres", "up"]),
            AgentProcess(pid: 12, ppid: 1, name: "amp", path: "/usr/local/bin/amp", args: ["amp"]),
            AgentProcess(pid: 20, ppid: 1, name: "goose", path: "/x/.local/bin/goose", args: ["goose", "session"]),
            AgentProcess(pid: 21, ppid: 1, name: "node", path: "/x/node", args: ["node", "/opt/homebrew/bin/copilot"])
        ]
        XCTAssertEqual(scan(processes).map(\.kind), [.goose, .copilot])
    }

    func testInterpreterOptionsWithValues() {
        let processes = [
            AgentProcess(pid: 10, ppid: 1, name: "node", path: "/x/node", args: ["node", "-r", "hook.js", "/x/bin/gemini", "-p", "update"]),
            AgentProcess(pid: 20, ppid: 1, name: "python3.12", path: "/x/python3.12", args: ["python3", "-X", "utf8", "/x/bin/aider"]),
            AgentProcess(pid: 30, ppid: 1, name: "python3.12", path: "/x/python3.12", args: ["python3", "-m", "aider", "--model", "x"])
        ]
        XCTAssertEqual(scan(processes).map(\.kind), [.gemini, .aider, .aider])
    }

    func testCodexAppServerBehindAShimFollowsItsChild() {
        let processes = [
            AgentProcess(pid: 10, ppid: 1, name: "node", path: "/x/node", args: ["node", "/x/bin/codex", "app-server"]),
            AgentProcess(pid: 11, ppid: 10, name: "codex", path: "/x/vendor/bin/codex", args: ["codex", "app-server"])
        ]
        XCTAssertEqual(scan(processes), [])
        XCTAssertEqual(scan(processes, codex: [11: .working]), [AgentSession(pid: 10, kind: .codex, working: true)])
    }

    func testEveryMemberIsAskedSoBaselinesStayFresh() {
        var asked: Set<Int32> = []
        let processes = [
            claude(10), caffeinate(11, parent: 10),
            AgentProcess(pid: 12, ppid: 10, name: "node", path: "/x/node", args: ["node", "/x/bin/gemini"])
        ]
        let sessions = AgentSessions.sessions(in: processes, uid: 501, codexTask: { _ in .noSessionFile },
                                              busy: { asked.formUnion($0); return false })
        XCTAssertEqual(sessions, [AgentSession(pid: 10, kind: .claude, working: true)])
        XCTAssertTrue(asked.contains(12))
    }

    func testStatusNamesAgentsByString() throws {
        let status = AgentSessionStatus(AgentSessionCount(agent: .codex, open: 2, working: 1))
        XCTAssertEqual(status, try JSONDecoder().decode(AgentSessionStatus.self, from: JSONEncoder().encode(status)))
        let future = #"{"agent":"newagent","name":"New Agent","open":1,"working":0}"#
        XCTAssertEqual(try JSONDecoder().decode(AgentSessionStatus.self, from: Data(future.utf8)).name, "New Agent")
    }

    func testArgumentsOfThisProcess() {
        XCTAssertFalse(AgentScanner.arguments(getpid()).isEmpty)
    }
    func testOldDescendantActivityAndIdleUseCPUSamples() {
        let scanner = AgentScanner()
        let processes = [AgentProcess(pid: 10, ppid: 1, name: "gemini", args: ["gemini"]),
                         AgentProcess(pid: 11, ppid: 10, name: "worker")]
        var childCPU: UInt64 = 1_000_000_000
        let usage: (Int32) -> (start: UInt64, cpu: UInt64, age: TimeInterval)? = { pid in
            (UInt64(pid), pid == 11 ? childCPU : 0, 3600)
        }
        let start = Date(timeIntervalSince1970: 100)
        func sample(_ seconds: TimeInterval) -> Bool? {
            scanner.scan(processes: processes, uid: 501, now: start.addingTimeInterval(seconds),
                         usage: usage, codexFiles: { _ in [:] }).sessions.first?.working
        }
        XCTAssertEqual(sample(0), false)
        childCPU += 500_000_000
        XCTAssertEqual(sample(1), true)
        XCTAssertEqual(sample(2), false)
    }

    func testAppServerCountsDistinctFilesAndTracksTransitions() {
        var processes = [
            AgentProcess(pid: 10, ppid: 1, name: "node", path: "/x/node", args: ["node", "/x/codex", "app-server"]),
            AgentProcess(pid: 11, ppid: 10, name: "codex", args: ["codex", "app-server"])
        ]
        var files: [Int32: [String: CodexTask]] = [
            10: ["a": .working, "b": .idle],
            11: ["a": .working, "b": .idle, "c": .working]
        ]
        func counts() -> [AgentSessionCount] {
            let sessions = AgentSessions.sessions(in: processes, uid: 501, codexTask: { _ in .noSessionFile },
                codexFiles: { files[$0] ?? [:] }, busy: { _ in false })
            return AgentSessionCount.tally(sessions)
        }
        XCTAssertEqual(counts(), [AgentSessionCount(agent: .codex, open: 3, working: 2)])
        files[10] = ["a": .idle, "b": .working]
        files[11] = ["a": .idle, "b": .working]
        XCTAssertEqual(counts(), [AgentSessionCount(agent: .codex, open: 2, working: 1)])
        processes[0].stopped = true
        XCTAssertEqual(counts(), [AgentSessionCount(agent: .codex, open: 2, working: 0)])
        files = [:]
        XCTAssertEqual(counts(), [])
    }

    func testAppServerNestedWorkCountsOnlyOneExistingSession() {
        let server = AgentProcess(pid: 10, ppid: 1, name: "codex", args: ["codex", "app-server"])
        let nested = AgentProcess(pid: 11, ppid: 10, name: "codex", args: ["codex", "exec", "--ephemeral"])
        var files: [String: CodexTask] = ["a": .idle]
        func counts(_ processes: [AgentProcess]) -> [AgentSessionCount] {
            AgentSessionCount.tally(AgentSessions.sessions(in: processes, uid: 501,
                codexTask: { _ in .noSessionFile }, codexFiles: { $0 == 10 ? files : [:] }, busy: { _ in false }))
        }
        XCTAssertEqual(counts([server, nested]), [AgentSessionCount(agent: .codex, open: 1, working: 1)])
        files["b"] = .idle
        XCTAssertEqual(counts([server, nested]), [AgentSessionCount(agent: .codex, open: 2, working: 1)])
        XCTAssertEqual(counts([server]), [AgentSessionCount(agent: .codex, open: 2, working: 0)])
        files["b"] = .working
        XCTAssertEqual(counts([server, nested]), [AgentSessionCount(agent: .codex, open: 2, working: 1)])
        files = [:]
        XCTAssertEqual(counts([server, nested]), [])
    }

    func testScannerSnapshotsMultipleAppServerFilesOncePerProcess() {
        let scanner = AgentScanner()
        let server = AgentProcess(pid: 10, ppid: 1, name: "codex", args: ["codex", "app-server"])
        var reads = 0
        let result = scanner.scan(processes: [server], uid: 501, now: .now, usage: { _ in nil }, codexFiles: { _ in
            reads += 1
            return ["a": .working, "b": .idle, "c": .working]
        })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(AgentSessionCount.tally(result.sessions), [AgentSessionCount(agent: .codex, open: 3, working: 2)])
    }

}
