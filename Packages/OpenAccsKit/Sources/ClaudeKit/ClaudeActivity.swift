import Foundation
import OpenAccsCore

/// Whether a Claude window is in the middle of something a restart would cut off: a Claude Code chat mid-turn
/// or with work it left running (a command, a background agent, a loop, a workflow), or a job in one of its
/// terminal tabs. Unknown counts as busy.
struct ClaudeActivity {
    struct Process: Sendable, Hashable {
        var pid: pid_t
        var parent: pid_t
        var path: String
    }

    var processes: [Process]
    var arguments: (pid_t) -> [String]?
    /// `~/.claude/projects`, where every chat's transcript lives.
    var projects: URL

    /// Stop reasons that end a turn; anything else (a tool call, no reason yet) means it's still going.
    static let finishedTurns: Set<String> = ["end_turn", "stop_sequence", "max_tokens", "refusal"]
    static let shells: Set<String> = ["zsh", "bash", "sh"]
    /// Tools whose work goes on after the turn ends.
    static let backgroundTools: Set<String> = ["ScheduleWakeup", "CronCreate", "Workflow", "Monitor"]
    /// Agents run on after the turn when started with `run_in_background`.
    static let agentTools: Set<String> = ["Agent", "Task"]

    func isBusy(window: pid_t) -> Bool {
        let children = Dictionary(grouping: processes, by: \.parent)
        var transcripts: TranscriptIndex?
        var queue = children[window] ?? []
        while let process = queue.popLast() {
            let kids = children[process.pid] ?? []
            guard Self.isChat(process) else {
                // A shell with a child is a job in a terminal tab: a dev server, a build, ssh.
                if Self.isShell(process), !kids.isEmpty { return true }
                queue.append(contentsOf: kids)
                continue
            }
            // Its own children are MCP servers and the commands it runs; a shell is a command.
            if kids.contains(where: Self.isShell) { return true }
            guard let id = Self.session(in: arguments(process.pid)) else { return true }
            if transcripts == nil { transcripts = TranscriptIndex(projects: projects) }
            guard transcripts?.lastTurn(id) == .finished, transcripts?.agentsWorking(id) == false else { return true }
        }
        return false
    }

    static func isShell(_ process: Process) -> Bool {
        shells.contains(URL(filePath: process.path).lastPathComponent)
    }

    /// The Claude Code CLI the desktop app runs for each open chat.
    static func isChat(_ process: Process) -> Bool {
        process.path.contains("/claude-code/") && process.path.hasSuffix("/MacOS/claude")
    }

    /// `--resume=<id>`, `--resume <id>` or the same with `--session-id`.
    static func session(in arguments: [String]?) -> String? {
        guard let arguments else { return nil }
        for (i, arg) in arguments.enumerated() {
            for flag in ["--resume", "--session-id"] {
                let value = arg.hasPrefix(flag + "=") ? String(arg.dropFirst(flag.count + 1))
                    : arg == flag && i + 1 < arguments.count ? arguments[i + 1] : nil
                if let value, FS.isSafeName(value) { return value }
            }
        }
        return nil
    }
}

enum TurnState: Equatable {
    /// The last turn ended and left nothing running.
    case finished
    case working
}

extension TranscriptIndex {
    /// How the chat's last main-thread turn stands, from the newest copy of its transcript: finished only
    /// when it ended and started nothing that keeps running (a background agent, a loop or schedule, a
    /// workflow, a monitor). nil when the transcript can't be read. Reads only the last megabyte.
    func lastTurn(_ id: String) -> TurnState? {
        file(for: id).flatMap { Self.lastTurn(in: $0, sidechains: false) }
    }

    /// True while an agent the chat started (any turn, a workflow's too) is mid-turn: a transcript under
    /// `<id>/subagents/` changed in the last day and doesn't end finished.
    func agentsWorking(_ id: String, now: Date = Date()) -> Bool {
        guard let file = file(for: id) else { return false }
        let dir = file.deletingPathExtension().appending(path: "subagents", directoryHint: .isDirectory)
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in files where url.pathExtension == "jsonl" && FS.isRegularFile(url) {
            guard let modified = FS.modificationDate(url), now.timeIntervalSince(modified) < 86_400 else { continue }
            if Self.lastTurn(in: url, sidechains: true) == .working { return true }
        }
        return false
    }

    /// `sidechains`: an agent's own transcript, where every entry is one.
    static func lastTurn(in file: URL, sidechains: Bool) -> TurnState? {
        guard let tail = ClaudeProfiles.tail(of: file, bytes: 1 << 20) else { return nil }
        var ended = false
        for line in tail.split(separator: 0x0A).reversed() {
            guard let entry = JSON.object(Data(line)), let type = entry["type"] as? String, type == "user" || type == "assistant",
                  sidechains || entry["isSidechain"] as? Bool != true else { continue }
            let message = entry["message"] as? [String: Any]
            let blocks = message?["content"] as? [[String: Any]] ?? []
            if type == "assistant" {
                if !ended {
                    guard let reason = message?["stop_reason"] as? String, ClaudeActivity.finishedTurns.contains(reason) else { return .working }
                    ended = true
                }
                for block in blocks where block["type"] as? String == "tool_use" {
                    let name = block["name"] as? String ?? ""
                    if ClaudeActivity.backgroundTools.contains(name) { return .working }
                    if ClaudeActivity.agentTools.contains(name), (block["input"] as? [String: Any])?["run_in_background"] as? Bool == true {
                        return .working
                    }
                }
            } else {
                // A prompt or tool result nobody answered yet.
                guard ended else { return .working }
                // The prompt that started the last turn: everything after it has been looked at.
                if !blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return .finished }
            }
        }
        return ended ? .finished : nil
    }
}
