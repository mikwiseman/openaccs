import Foundation
import Testing
@testable import ClaudeKit

private let cliPath = "/Users/x/Library/Application Support/Claude/claude-code/2.1.304/abc/claude.app/Contents/MacOS/claude"

/// One Claude window (pid 10) with a disclaimer (11) and Claude Code chats under it.
private struct Window {
    var processes: [ClaudeActivity.Process] = [
        .init(pid: 10, parent: 1, path: "/Applications/Claude.app/Contents/MacOS/Claude"),
        .init(pid: 11, parent: 10, path: "/Applications/Claude.app/Contents/Helpers/disclaimer"),
    ]
    var arguments: [pid_t: [String]] = [:]

    mutating func chat(_ pid: pid_t, session: String?, under parent: pid_t = 11) {
        processes.append(.init(pid: pid, parent: parent, path: cliPath))
        processes.append(.init(pid: pid + 1, parent: pid, path: "/usr/local/bin/node"))   // its MCP server
        arguments[pid] = [cliPath, "--output-format", "stream-json"] + (session.map { ["--resume=\($0)"] } ?? [])
    }

    func activity(_ home: TempHome) -> ClaudeActivity {
        let arguments = self.arguments
        return ClaudeActivity(processes: processes, arguments: { arguments[$0] },
                              projects: home.url.appending(path: ".claude/projects", directoryHint: .isDirectory))
    }
}

extension TempHome {
    fileprivate func transcript(_ id: String, _ lines: [String]) throws {
        try write(".claude/projects/-Users-x-proj/\(id).jsonl", lines.joined(separator: "\n") + "\n")
    }
}

private let finished = [
    #"{"type":"user","message":{"role":"user","content":"Fix it"}}"#,
    #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#,
    #"{"type":"system","subtype":"turn_duration"}"#,
]

@Suite struct ClaudeActivityTests {
    @Test func idleWhenEveryChatFinishedItsTurn() throws {
        let home = try TempHome()
        let id = UUID().uuidString.lowercased()
        try home.transcript(id, finished)
        var window = Window()
        window.chat(20, session: id)
        #expect(!window.activity(home).isBusy(window: 10))
    }

    @Test func busyMidTurnWhileAShellRunsOrWhenUnsure() throws {
        let home = try TempHome()
        let done = UUID().uuidString.lowercased(), working = UUID().uuidString.lowercased()
        try home.transcript(done, finished)
        try home.transcript(working, [
            #"{"type":"user","message":{"role":"user","content":"Release it"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"stop_reason":"end_turn","content":[]}}"#,
        ])

        var midTurn = Window()
        midTurn.chat(20, session: done)
        midTurn.chat(30, session: working)
        #expect(midTurn.activity(home).isBusy(window: 10))

        // A finished turn that left a command running (a background task).
        var shell = Window()
        shell.chat(20, session: done)
        shell.processes.append(.init(pid: 40, parent: 20, path: "/bin/zsh"))
        #expect(shell.activity(home).isBusy(window: 10))

        // A chat whose transcript can't be found, or whose id can't be read.
        var missing = Window()
        missing.chat(20, session: UUID().uuidString.lowercased())
        #expect(missing.activity(home).isBusy(window: 10))
        var anonymous = Window()
        anonymous.chat(20, session: nil)
        #expect(anonymous.activity(home).isBusy(window: 10))
    }

    @Test func jobsInTerminalTabsCountButIdleTabsDont() throws {
        let home = try TempHome()
        let done = UUID().uuidString.lowercased()
        try home.transcript(done, finished)
        var window = Window()
        window.chat(20, session: done)
        window.processes.append(.init(pid: 80, parent: 10, path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"))
        window.processes.append(.init(pid: 81, parent: 80, path: "/bin/zsh"))   // an idle tab
        #expect(!window.activity(home).isBusy(window: 10))
        window.processes.append(.init(pid: 82, parent: 80, path: "/bin/zsh"))
        window.processes.append(.init(pid: 83, parent: 82, path: "/usr/local/bin/npm"))   // npm run dev
        #expect(window.activity(home).isBusy(window: 10))
    }

    @Test func workLeftRunningAfterTheTurnCounts() throws {
        let home = try TempHome()
        var window = Window()
        let cases: [(String, Bool)] = [
            (#"{"type":"tool_use","name":"Agent","input":{"prompt":"x","run_in_background":true}}"#, true),
            (#"{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":600}}"#, true),
            (#"{"type":"tool_use","name":"Workflow","input":{}}"#, true),
            (#"{"type":"tool_use","name":"Agent","input":{"prompt":"x"}}"#, false),   // a foreground agent ended with the turn
        ]
        for (i, (call, busy)) in cases.enumerated() {
            let id = UUID().uuidString.lowercased()
            try home.transcript(id, [
                #"{"type":"user","message":{"role":"user","content":"Go"}}"#,
                #"{"type":"assistant","message":{"stop_reason":"tool_use","content":["# + call + #"]}}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"started"}]}}"#,
                #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"On it"}]}}"#,
            ])
            window = Window()
            window.chat(pid_t(20 + i * 10), session: id)
            #expect(window.activity(home).isBusy(window: 10) == busy)
        }
    }

    @Test func anAgentStartedEarlierThatStillWorksCounts() throws {
        let home = try TempHome()
        let id = UUID().uuidString.lowercased()
        try home.transcript(id, finished)   // the chat moved on after starting it
        var window = Window()
        window.chat(20, session: id)
        #expect(!window.activity(home).isBusy(window: 10))
        try home.write(".claude/projects/-Users-x-proj/\(id)/subagents/agent-a1.jsonl", [
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"Research"}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"WebSearch"}]}}"#,
        ].joined(separator: "\n") + "\n")
        #expect(window.activity(home).isBusy(window: 10))
        // Done agents (and a workflow's journal, which isn't a transcript) don't count.
        try home.write(".claude/projects/-Users-x-proj/\(id)/subagents/agent-a1.jsonl", [
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"Research"}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Found it"}]}}"#,
        ].joined(separator: "\n") + "\n")
        try home.write(".claude/projects/-Users-x-proj/\(id)/subagents/workflows/wf_1/journal.jsonl", #"{"type":"result"}"# + "\n")
        #expect(!window.activity(home).isBusy(window: 10))
    }

    @Test func theNewestCopyOfATranscriptDecides() throws {
        let home = try TempHome()
        let id = UUID().uuidString.lowercased()
        let old = try home.write(".claude/projects/-a/\(id).jsonl", finished.joined(separator: "\n") + "\n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        try home.write(".claude/projects/-b/\(id).jsonl", [
            #"{"type":"user","message":{"role":"user","content":"Go on"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}"#,
        ].joined(separator: "\n") + "\n")
        var window = Window()
        window.chat(20, session: id)
        #expect(window.activity(home).isBusy(window: 10))
    }

    @Test func onlyThisWindowsChatsCount() throws {
        let home = try TempHome()
        let done = UUID().uuidString.lowercased()
        try home.transcript(done, finished)
        var window = Window()
        window.chat(20, session: done)
        // Another Claude window (50) is in the middle of a command.
        window.processes.append(.init(pid: 50, parent: 1, path: "/Applications/Claude.app/Contents/MacOS/Claude"))
        window.processes.append(.init(pid: 51, parent: 50, path: "/Applications/Claude.app/Contents/Helpers/disclaimer"))
        window.chat(60, session: done, under: 51)
        window.processes.append(.init(pid: 70, parent: 60, path: "/bin/zsh"))
        #expect(!window.activity(home).isBusy(window: 10))
        #expect(window.activity(home).isBusy(window: 50))
    }
}
