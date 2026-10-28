import Foundation
import OpenAccsCore
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

    var folders: [pid_t: String] = [:]

    func activity(_ home: TempHome) -> ClaudeActivity {
        let arguments = self.arguments, folders = self.folders
        var activity = ClaudeActivity(processes: processes, arguments: { arguments[$0] },
                                      projects: home.url.appending(path: ".claude/projects", directoryHint: .isDirectory))
        activity.workingDirectory = { folders[$0] }
        return activity
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

    @Test func findsTheWindowRunningAChat() throws {
        let home = try TempHome()
        var window = Window()
        window.chat(20, session: "s1")
        window.processes.append(.init(pid: 50, parent: 1, path: "/Applications/Claude.app/Contents/MacOS/Claude"))
        window.processes.append(.init(pid: 51, parent: 50, path: "/Applications/Claude.app/Contents/Helpers/disclaimer"))
        window.chat(60, session: nil, under: 51)   // a chat started after that window launched: no id in its arguments
        window.folders[60] = "/Users/x/new"
        let now = Date()
        let activity = window.activity(home)
        #expect(activity.window(runningChat: "s1", cwd: nil, at: now) == 10)
        #expect(activity.window(runningChat: "s2", cwd: "/Users/x/new", at: now) == 50)
        #expect(activity.window(runningChat: "s2", cwd: "/Users/x/elsewhere", at: now) == nil)

        // Opened in window 50 too (resumed there after the refusal): only the process running then counts.
        var moved = window
        moved.chat(70, session: "s1", under: 51)
        moved.processes = moved.processes.map { var p = $0; if p.pid == 70 { p.started = now.addingTimeInterval(60) }; return p }
        #expect(moved.activity(home).window(runningChat: "s1", cwd: nil, at: now) == 10)
        // Running in both windows at that time: can't tell.
        var both = window
        both.chat(70, session: "s1", under: 51)
        #expect(both.activity(home).window(runningChat: "s1", cwd: nil, at: now) == nil)
        // A terminal `claude` in the same folder may have written it under its own login: can't tell.
        var terminal = window
        terminal.processes.append(.init(pid: 90, parent: 1, path: "/Users/x/.local/share/claude/versions/2.1.307"))
        terminal.folders[90] = "/Users/x/new"
        #expect(terminal.activity(home).window(runningChat: "s2", cwd: "/Users/x/new", at: now) == nil)
    }

    @Test func limitHitsComeFromClaudeCodesOwnRejection() throws {
        let home = try TempHome()
        let file = try home.write(".claude/projects/-p/s1.jsonl", [
            #"{"type":"user","timestamp":"2026-10-22T07:00:00.000Z","message":{"role":"user","content":"Go"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-22T07:11:39.876Z","cwd":"/Users/x/proj","sessionId":"s1","error":"rate_limit","isApiErrorMessage":true,"apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1792664400,"rateLimitType":"five_hour"}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-22T07:12:00.000Z","cwd":"/Users/x/proj","sessionId":"s1","error":"rate_limit","isApiErrorMessage":true,"quotaLimits":{"status":"rejected","resetsAt":1793000000,"rateLimitType":"seven_day"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-22T07:13:00.000Z","sessionId":"s1","message":{"stop_reason":"end_turn","content":[]}}"#,
        ].joined(separator: "\n") + "\n")
        let hits = LimitHit.read(file, since: .distantPast)
        #expect(hits.map(\.kind) == [.fiveHour, .weekly])
        #expect(hits.first?.resetsAt == Date(timeIntervalSince1970: 1_792_664_400))
        #expect(hits.first?.sessionId == "s1" && hits.first?.cwd == "/Users/x/proj")
        // Only the ones after `since`.
        let later = try #require(ISO8601DateFormatter().date(from: "2026-10-22T07:11:50Z"))
        #expect(LimitHit.read(file, since: later).map(\.kind) == [.weekly])
    }

    @Test func aLimitHitEmptiesThatWindowUntilItsReset() {
        let now = Date()
        let hit = LimitHit(kind: .fiveHour, resetsAt: now.addingTimeInterval(3600), at: now.addingTimeInterval(-60), sessionId: "s", cwd: nil)
        // No numbers at all: the hit alone says when it's back.
        let alone = UsageSnapshot.with([hit], on: nil, now: now)
        #expect(alone?.window(.fiveHour) == UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: hit.resetsAt))
        // Older numbers (the Claude app's) give way; the other window stays.
        let old = UsageSnapshot(windows: [UsageWindow(kind: .fiveHour, usedPercent: 40), UsageWindow(kind: .weekly, usedPercent: 70)],
                                asOf: now.addingTimeInterval(-7200), source: "Claude app")
        let merged = UsageSnapshot.with([hit], on: old, now: now)
        #expect(merged?.windows.map(\.kind) == [.fiveHour, .weekly])
        #expect(merged?.window(.fiveHour)?.resetsAt == hit.resetsAt)
        #expect(merged?.window(.weekly)?.usedPercent == 70)
        // Exact numbers taken after the refusal win.
        let exact = UsageSnapshot(windows: [UsageWindow(kind: .fiveHour, usedPercent: 10, resetsAt: now.addingTimeInterval(9000))],
                                  asOf: now, source: "Claude Code")
        #expect(UsageSnapshot.with([hit], on: exact, now: now) == exact)
        // The app's sample written after the refusal (at quit) has no reset time: it gets the hit's.
        let quit = UsageSnapshot(windows: [UsageWindow(kind: .fiveHour, usedPercent: 100)], asOf: now, source: "Claude app")
        #expect(UsageSnapshot.with([hit], on: quit, now: now)?.window(.fiveHour)?.resetsAt == hit.resetsAt)
        // Once the reset passed, that window is free again, until a sample from after the reset says more.
        let reset = LimitHit(kind: .fiveHour, resetsAt: now.addingTimeInterval(-1), at: now.addingTimeInterval(-3600), sessionId: "s", cwd: nil)
        #expect(UsageSnapshot.with([reset], on: old, now: now)?.window(.fiveHour)?.usedPercent == 0)
        let after = UsageSnapshot(windows: [UsageWindow(kind: .fiveHour, usedPercent: 20)], asOf: now, source: "Claude app")
        #expect(UsageSnapshot.with([reset], on: after, now: now) == after)
        // Without numbers, a limit that already came back says nothing (never a lasting "100% left").
        #expect(UsageSnapshot.with([reset], on: nil, now: now) == nil)
        #expect(UsageSnapshot.with([reset, hit], on: nil, now: now)?.windows == [UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: hit.resetsAt)])
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
