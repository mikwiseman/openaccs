import SwiftUI
import OpenAccsCore

/// Everything the panel shows and does. `AppModel` implements it for real, `DemoModel` for snapshots.
/// Async actions throw a `LocalizedError` whose description the panel shows as is.
@MainActor
protocol PanelModel: AnyObject, Observable {
    /// Every account in display order. The panel groups them into Claude, Codex and Limits.
    var rows: [PanelRow] { get }
    /// Usage of the Claude account used last: the menu-bar gauge (outer arc 5h, inner arc 7d).
    var menuBarUsage: UsageSnapshot? { get }
    var isRefreshing: Bool { get }
    /// Something the user should know that isn't about one account (e.g. accounts.json unreadable).
    var notice: String? { get }
    var launchAtLogin: Bool { get set }
    var syncPins: Bool { get set }
    /// Grok Bot accounts found on this Mac that are not added yet.
    var grokBotAccounts: [String] { get }

    /// Claude: activate or launch the profile. Codex: quit, swap, relaunch (the panel asks first).
    /// Limits: open the provider's usage page.
    func open(_ id: UUID) async throws
    /// Quit and relaunch a running Claude profile so it loads the sessions it hasn't seen.
    func restart(_ id: UUID) async throws
    /// Signs Anthropic's Claude Code in (browser) for the account this window shows: every window of that
    /// account gets its live limits.
    func connectExactLimits(_ id: UUID) async throws
    func rename(_ id: UUID, to label: String)
    func setColor(_ id: UUID, to color: Int)
    func remove(_ id: UUID)
    func revealFolder(_ id: UUID)
    func refresh()
    func quit()

    /// Launch a new Claude profile; the user signs in inside that window.
    func addClaude(label: String) async throws
    /// `codex login` in the browser; returns when the account is saved.
    func addCodex() async throws
    func addGrokCLI() async throws
    func addGrokBot(account: String) async throws
    /// `region` is "global" or "china".
    func addKimi(key: String, region: String) async throws
    func addZai(key: String, region: String) async throws
}

/// One account as the panel draws it.
struct PanelRow: Identifiable, Hashable {
    enum State: Hashable {
        /// Codex: the account in `~/.codex/auth.json`. Limits: connected.
        case active
        /// Claude: the profile's app is open.
        case running
        case idle
    }

    var id: UUID
    var provider: Provider
    var label: String
    /// Index into `AccountColor.all`.
    var color: Int
    var plan: String?
    var state: State
    var usage: UsageSnapshot?
    /// Why usage is missing or may be wrong ("Network: offline"). nil when fine.
    var error: String?
    /// Signed out. Claude: no live limits, and the row's one Connect fixes it.
    var needsSignIn: Bool = false
    /// Claude: sessions from other profiles this running profile hasn't loaded yet.
    var pendingSessions: Int = 0
    /// Claude: chats, pins and app settings that differ from the other windows', shown here after a restart.
    var pendingChanges: Int = 0
    /// Most room left among this provider's accounts.
    var isBest: Bool = false
    /// Claude: shows Claude Code's live numbers.
    var isLive: Bool = false
    /// Claude: the account and org the window shows. Windows with the same one share one sign-in.
    var limitsGroup: String?
    /// Has a data folder to show in Finder.
    var hasFolder: Bool = false
    /// Claude: the link of a Claude Code sign-in running for this window, from the panel or the terminal.
    var signInLink: URL?
}
