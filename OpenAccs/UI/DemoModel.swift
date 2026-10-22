import SwiftUI
import OpenAccsCore

/// Realistic stand-in data for snapshots and UI work. Actions only pretend.
/// `OPENACCS_DEMO=empty` starts with no accounts; `OPENACCS_DEMO=long` adds every edge case.
@MainActor @Observable
final class DemoModel: PanelModel {
    var rows: [PanelRow]
    var isRefreshing = false
    var notice: String?
    var launchAtLogin = true
    var grokBotAccounts = ["google-oauth2|user_2f8c41d7a90e"]

    var menuBarUsage: UsageSnapshot? { rows.first?.usage }

    init(now: Date = Date()) {
        // A little slack so "1h 12m" doesn't tick to "1h 11m" while a snapshot renders.
        func inMinutes(_ m: Int) -> Date { now.addingTimeInterval(Double(m) * 60 + 30) }
        func next(_ weekday: Int, hour: Int) -> Date {
            Calendar.current.nextDate(after: now, matching: DateComponents(hour: hour, minute: 0, weekday: weekday),
                                      matchingPolicy: .nextTime) ?? now
        }
        func usage(_ plan: String?, _ windows: [UsageWindow], resets: Int? = nil, credits: Credits? = nil,
                   minutesAgo: Int = 1, source: String = "ChatGPT") -> UsageSnapshot {
            UsageSnapshot(plan: plan, windows: windows, credits: credits, resetsAvailable: resets,
                          asOf: now.addingTimeInterval(Double(-minutesAgo * 60)), source: source)
        }
        let thu = next(5, hour: 9), fri = next(6, hour: 14), sat = next(7, hour: 11), mon = next(2, hour: 18)

        rows = [
            PanelRow(
                id: UUID(), provider: .claude, label: "me@example.com", color: 0, plan: "Max", state: .running,
                usage: usage("Max", [
                    UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: inMinutes(72)),
                    UsageWindow(kind: .weekly, usedPercent: 85, resetsAt: thu),
                ], source: "Claude Code"),
                hasFolder: true
            ),
            PanelRow(
                id: UUID(), provider: .claude, label: "work@example.com", color: 1, plan: "Team", state: .running,
                usage: usage("Team", [
                    UsageWindow(kind: .fiveHour, usedPercent: 2, resetsAt: inMinutes(4 * 60 + 21)),
                    UsageWindow(kind: .weekly, usedPercent: 14, resetsAt: mon),
                ], minutesAgo: 4, source: "Claude app"),
                pendingSessions: 3, isBest: true, canConnectLimits: true, hasFolder: true
            ),
            PanelRow(
                id: UUID(), provider: .codex, label: "me@example.com", color: 2, plan: "Pro", state: .active,
                usage: usage("Pro", [
                    UsageWindow(kind: .fiveHour, usedPercent: 31, resetsAt: inMinutes(3 * 60 + 2)),
                    UsageWindow(kind: .weekly, usedPercent: 88, resetsAt: fri),
                ], resets: 0)
            ),
            PanelRow(
                id: UUID(), provider: .codex, label: "team@example.com", color: 3, plan: "Plus", state: .idle,
                usage: usage("Plus", [
                    UsageWindow(kind: .fiveHour, usedPercent: 20, resetsAt: inMinutes(2 * 60 + 40)),
                    UsageWindow(kind: .weekly, usedPercent: 41, resetsAt: next(1, hour: 8)),
                ], resets: 1),
                isBest: true
            ),
            PanelRow(
                id: UUID(), provider: .grok, label: "Grok", color: 7, plan: "SuperGrok", state: .active,
                usage: usage("SuperGrok", [UsageWindow(kind: .weekly, usedPercent: 47, resetsAt: sat)],
                             minutesAgo: 125, source: "Grok Bot")
            ),
            PanelRow(
                id: UUID(), provider: .zai, label: "Z.ai", color: 5, plan: "Pro", state: .active,
                usage: usage("Pro", [
                    UsageWindow(kind: .fiveHour, usedPercent: 12, resetsAt: inMinutes(3 * 60 + 5)),
                    UsageWindow(kind: .weekly, usedPercent: 33, resetsAt: next(4, hour: 10)),
                ], source: "API key")
            ),
            PanelRow(
                id: UUID(), provider: .kimi, label: "Kimi", color: 4, plan: nil, state: .idle,
                usage: nil, error: "Key no longer works", needsSignIn: true
            ),
        ]

        switch ProcessInfo.processInfo.environment["OPENACCS_DEMO"] {
        case "empty":
            rows = []
        case "long":
            notice = "accounts.json could not be read. Showing what OpenAccs found on this Mac."
            rows.insert(contentsOf: [
                PanelRow(
                    id: UUID(), provider: .claude, label: "a.very.long.name.for.a.person@subsidiary.example.com",
                    color: 3, plan: "Enterprise", state: .idle,
                    usage: usage("Enterprise", [
                        UsageWindow(kind: .fiveHour, usedPercent: 0, resetsAt: nil),
                        UsageWindow(kind: .weekly, usedPercent: 99.6, resetsAt: thu),
                    ], credits: Credits(amount: 4.2, currency: "USD", label: "extra usage")),
                    hasFolder: true
                ),
                PanelRow(
                    id: UUID(), provider: .claude, label: "Side project", color: 5, plan: nil, state: .idle,
                    usage: nil, error: "Open this profile once to see limits", canConnectLimits: true, hasFolder: true
                ),
                PanelRow(
                    id: UUID(), provider: .claude, label: "Lab", color: 6, plan: "Pro", state: .running,
                    usage: usage("Pro", [
                        UsageWindow(kind: .fiveHour, usedPercent: 64, resetsAt: inMinutes(14)),
                        UsageWindow(kind: .weekly, usedPercent: 100, resetsAt: sat),
                    ], source: "Claude Code"),
                    pendingSessions: 1, pendingChanges: 2, hasFolder: true
                ),
                PanelRow(
                    id: UUID(), provider: .claude, label: "Old login", color: 7, plan: "Max", state: .idle,
                    usage: nil, error: "Sign in again", needsSignIn: true, hasFolder: true
                ),
            ], at: 2)
            rows.append(contentsOf: [
                PanelRow(
                    id: UUID(), provider: .codex, label: "ops@example.com", color: 4, plan: "Business", state: .idle,
                    usage: nil, error: "Offline"
                ),
                PanelRow(
                    id: UUID(), provider: .kimi, label: "Moonshot team", color: 1, plan: "Andante", state: .active,
                    usage: usage("Andante", [
                        UsageWindow(kind: .fiveHour, usedPercent: 79, resetsAt: inMinutes(48)),
                        UsageWindow(kind: .weekly, usedPercent: 81, resetsAt: fri),
                        UsageWindow(kind: .monthly, usedPercent: 52, resetsAt: now.addingTimeInterval(19 * 86400)),
                    ], credits: Credits(amount: 12, currency: "USD", label: "wallet"), minutesAgo: 3 * 24 * 60, source: "API key")
                ),
                PanelRow(
                    id: UUID(), provider: .zai, label: "Z.ai China", color: 0, plan: nil, state: .idle,
                    usage: nil, error: "No plan with limits"
                ),
            ])
        default:
            break
        }
    }

    func open(_ id: UUID) async throws {
        try await Task.sleep(for: .milliseconds(600))
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[i].provider == .codex {
            try await Task.sleep(for: .seconds(2))
            for j in rows.indices where rows[j].provider == .codex { rows[j].state = j == i ? .active : .idle }
        } else if rows[i].provider == .claude {
            rows[i].state = .running
        }
    }

    func restart(_ id: UUID) async throws {
        try await Task.sleep(for: .seconds(2))
        update(id) { $0.pendingSessions = 0 }
    }

    func connectExactLimits(_ id: UUID) async throws {
        try await Task.sleep(for: .seconds(2))
        update(id) { $0.canConnectLimits = false }
    }

    func rename(_ id: UUID, to label: String) { update(id) { $0.label = label } }
    func setColor(_ id: UUID, to color: Int) { update(id) { $0.color = color } }
    func remove(_ id: UUID) { rows.removeAll { $0.id == id } }
    func revealFolder(_ id: UUID) {}

    func refresh() {
        isRefreshing = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            isRefreshing = false
        }
    }

    func quit() { NSApplication.shared.terminate(nil) }

    func addClaude(label: String) async throws {
        try await Task.sleep(for: .seconds(1))
        rows.insert(PanelRow(id: UUID(), provider: .claude, label: label, color: 5, plan: nil, state: .running,
                             canConnectLimits: true, hasFolder: true),
                    at: rows.lastIndex { $0.provider == .claude }.map { $0 + 1 } ?? 0)
    }

    func addCodex() async throws {
        try await Task.sleep(for: .seconds(3))
        throw DemoError("Sign-in was cancelled in the browser.")
    }

    func addGrokCLI() async throws {
        try await Task.sleep(for: .seconds(2))
        throw DemoError("The grok CLI is not installed.")
    }

    func addGrokBot(account: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
        grokBotAccounts.removeAll { $0 == account }
    }

    func addKimi(key: String, region: String) async throws {
        try await Task.sleep(for: .seconds(1))
        throw DemoError("Kimi didn't accept this key.")
    }

    func addZai(key: String, region: String) async throws {
        try await Task.sleep(for: .seconds(1))
    }

    private func update(_ id: UUID, _ change: (inout PanelRow) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[i])
    }
}

private struct DemoError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
