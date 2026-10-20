import SwiftUI
import OpenAccsCore

/// Realistic stand-in data for snapshots and UI work. Actions only pretend.
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
        let soon = now.addingTimeInterval(72 * 60 + 30)
        func next(_ weekday: Int, hour: Int) -> Date {
            Calendar.current.nextDate(after: now, matching: DateComponents(hour: hour, minute: 0, weekday: weekday),
                                      matchingPolicy: .nextTime) ?? now
        }
        let thu = next(5, hour: 9), fri = next(6, hour: 14), sat = next(7, hour: 11)
        let ids = (0..<7).map { _ in UUID() }

        rows = [
            PanelRow(
                id: ids[0], provider: .claude, label: "me@example.com", color: 0, plan: "Max", state: .running,
                usage: UsageSnapshot(plan: "Max", windows: [
                    UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: soon),
                    UsageWindow(kind: .weekly, usedPercent: 85, resetsAt: thu),
                ], asOf: now.addingTimeInterval(-90), source: "Claude Code"),
                hasFolder: true
            ),
            PanelRow(
                id: ids[1], provider: .claude, label: "work@example.com", color: 1, plan: "Team", state: .running,
                usage: UsageSnapshot(plan: "Team", windows: [
                    UsageWindow(kind: .fiveHour, usedPercent: 2, resetsAt: now.addingTimeInterval(4 * 3600 + 21 * 60 + 30)),
                    UsageWindow(kind: .weekly, usedPercent: 14, resetsAt: next(2, hour: 18)),
                ], asOf: now.addingTimeInterval(-240), source: "Claude app"),
                pendingSessions: 3, isBest: true, canConnectLimits: true, hasFolder: true
            ),
            PanelRow(
                id: ids[2], provider: .codex, label: "me@example.com", color: 2, plan: "Pro", state: .active,
                usage: UsageSnapshot(plan: "Pro", windows: [
                    UsageWindow(kind: .weekly, usedPercent: 88, resetsAt: fri),
                ], resetsAvailable: 0,
                asOf: now.addingTimeInterval(-60), source: "ChatGPT")
            ),
            PanelRow(
                id: ids[3], provider: .codex, label: "team@example.com", color: 3, plan: "Plus", state: .idle,
                usage: UsageSnapshot(plan: "Plus", windows: [
                    UsageWindow(kind: .fiveHour, usedPercent: 20, resetsAt: now.addingTimeInterval(2 * 3600 + 40 * 60 + 30)),
                    UsageWindow(kind: .weekly, usedPercent: 41, resetsAt: next(1, hour: 8)),
                ], resetsAvailable: 1, asOf: now.addingTimeInterval(-60), source: "ChatGPT"),
                isBest: true
            ),
            PanelRow(
                id: ids[4], provider: .grok, label: "Grok", color: 7, plan: "SuperGrok", state: .active,
                usage: UsageSnapshot(plan: "SuperGrok", windows: [
                    UsageWindow(kind: .weekly, usedPercent: 47, resetsAt: sat),
                ], asOf: now.addingTimeInterval(-2 * 3600 - 300), source: "Grok Bot")
            ),
            PanelRow(
                id: ids[5], provider: .zai, label: "Z.ai", color: 5, plan: "Pro", state: .active,
                usage: UsageSnapshot(plan: "Pro", windows: [
                    UsageWindow(kind: .fiveHour, usedPercent: 12, resetsAt: now.addingTimeInterval(3 * 3600 + 5 * 60 + 30)),
                    UsageWindow(kind: .weekly, usedPercent: 33, resetsAt: next(4, hour: 10)),
                ], asOf: now.addingTimeInterval(-60), source: "API key")
            ),
            PanelRow(
                id: ids[6], provider: .kimi, label: "Kimi", color: 4, plan: nil, state: .idle,
                usage: nil, error: "Key no longer works", needsSignIn: true
            ),
        ]
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
