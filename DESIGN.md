# OpenAccs — design

*Switch accounts. Keep your work.*

A macOS menu-bar app for many AI accounts: Claude and Codex accounts you can switch between inside the desktop apps, with one shared history per product, plus usage limits for Claude, Codex, Grok, Kimi and Z.ai.

## Principles

1. **Use the existing sign-in.** Claude limits read only the selected desktop profile's session cookie, decrypted with user-authorized access to Claude Safe Storage. Keep it in memory, send it only to `claude.ai`, and verify its account before requesting limits. No extra login or persistent cookie copy. This is a private desktop API, not an official third-party integration.
2. **One work environment per product.** Claude profiles share `~/.claude`. Codex profiles share configuration, instructions, skills, local chat database and transcripts; each keeps its own sign-in and browser data. No live sidebar synchronization or implicit restarts.
3. **One popover.** Accounts grouped by product. Each row says who and how much is left. Click = switch.
4. **Never lose data.** Every write is atomic. Never edit a file a running app holds. Anything OpenAccs replaces or removes is copied to `~/Library/Application Support/OpenAccs/Backups/` first.

## Facts this design rests on (verified on this Mac, Claude 2.42304.2, Codex app 26.1013, codex-cli 0.163)

Claude desktop
- `--user-data-dir` works for the signed build; `CLAUDE_USER_DATA_DIR` is ignored. Launch extra profiles via LaunchServices with a new instance (`NSWorkspace.OpenConfiguration.createsNewApplicationInstance = true`, `arguments: ["--user-data-dir=<dir>"]`). The default profile is launched with no arguments.
- **No single-instance lock.** Two processes on one data folder corrupt it. OpenAccs must map running Claude main processes (bundle `com.anthropic.claudefordesktop`, argv without `--type=`) to their data folder and activate instead of launching twice.
- Instances look identical in Dock/⌘-Tab. OpenAccs is how you pick one.
- Code-tab session cards: `<dataDir>/claude-code-sessions/<accountUuid>/<orgUuid>/local_<uuid>.json`; file name must equal `sessionId + ".json"`. Account and org = the folder the app loaded last: latest `Loaded N persisted sessions from <dataDir>/claude-code-sessions/<acct>/<org>` line in `~/Library/Logs/Claude/main*.log`, else a folder of the account the profile was added with (recorded the first time the log names one), else the `<acct>/<org>` folder with the newest card. Only the last 4 MB of each log is read, newest log first, and an older log counts only when every newer one was read whole: what a newer log said before its last 4 MB is newer than anything in an older one. OpenAccs never opens `config.json` (it holds Claude's encrypted login caches).
- A profile keeps one card folder per account ever signed in there; the app reads a folder again when that account signs in (logout → login in the same window).
- **Cards are read only when the app initializes** (launch, sign-in, account/org switch). A running app never re-reads a card it holds and overwrites cards from memory. So: never edit or delete a card in a running profile. Creating a NEW card file (exclusive create) in a running profile is safe; it appears at the next launch.
- Transcripts: `<CLAUDE_CONFIG_DIR>/projects/<encoded-cwd>/<cliSessionId>.jsonl` (+ `<cliSessionId>/subagents/*.jsonl`). The desktop resumes with the card's `cliSessionId` and re-reads the transcript from disk, so a shared `~/.claude` shares content automatically.
- The Code tab authenticates with a token the desktop passes in the environment, never the CLI keychain item, so profiles on different accounts can share `~/.claude`. Leave CLAUDE_CONFIG_DIR unset (setting it to `~/.claude` explicitly changes which `.claude.json` is used).
- Never use symlinks or hard links for cards, card folders or transcripts (saves fail or files are refused). Never write temp files named `local_*.json.tmp` (the app promotes them).
- Deleting a session writes `deleted_<cliSessionId>` in that account folder.
- Account-bound card fields must never be copied: bridgeSessionIds, bridgeSessionId, cloudSessionId, movedToCloud, remoteControl*, steeredByRemoteClient, envScopeId, remoteMcpServersConfig, withheldConnectorHosts, enabledMcpTools, scheduledTaskId, startedFromEnvironmentId, emailAddress, worktreePath, worktreeName, branch, folderWorktrees, keptDirtyWorktree, worktreeLazy, stagedTranscriptPath, importedFrom, resumeConfirmed, peerReceipts, peerInbound, peerMessaged, spawnedFrom, dispatchParent*, forkedFromSessionId, sessionPermissionUpdates, alwaysAllowedReasons, cuAllowedApps, cuGrantFlags, chromeAllowedDomains, spawnSeed, sshRemoteProcessId, pendingSystemReminder, spaceId, publishedArtifacts.
- `<dataDir>/plan-usage-history.json` = `{version:2, samples:[{t (ms), org, u:{fh (5h %), sd (7d %), so, sn, oa, cw, om, op, xu}}]}`, appended when the app refreshes its usage card, never within 4.5 minutes of that org's last sample (Claude 3.6556: every ~10 minutes in a busy window, only at launch in another; a closed window not at all). Keyed by org, not account. No reset times. Credential-free fallback only: a quiet window can retain an old sample, so always preserve its timestamp and fade stale numbers.
- App settings (Claude 3.6556): main-process preferences live only in `claude_desktop_config.json` (`preferences.*`, `mcpServers`). The Code tab keeps its own in localStorage (origin `https://claude.ai`) and copies them out: `preferences.epitaxyPrefs.<key>` = `LSS-persisted.<key>` (`{"value":…,"tabId":"","timestamp":ms}`), and new-session defaults = `persisted.ccd-session-presets.<accountUuid>` (zustand `{state:{presets, builtIns:{local:{settings:{modelId, effort, fastMode, worktree}}}, fileMirrored, …}, version:4}`), copied to `<dataDir>/ccd-session-presets.json` `byAccount.<accountUuid>`. At launch the app reads localStorage and a copy only while localStorage has none. `epitaxyPrefs.fastMode` and `cc-landing-draft-permission-mode` are the composer's state, set from the new-session defaults at every launch. The sidebar's layout is the zustand store `dframe-store` (`state.codeSidebarByScope["<acct>/<org>"].sections`; `epitaxyPrefs["dframe-code-sections"]` is its copy), which Claude syncs per account through its servers (`ccd-sync-owner`, `ccd-sync-pending:ccd/dframe-store`) and replaces at every launch: a local write is undone, so it can't be shared across accounts.
- Claude in Chrome: a window started with `--user-data-dir` logs "local pairing disabled for this launch: userData relocated" and uses only `wss://bridge.claudeusercontent.com/chrome/<accountUuid>`, which finds an extension signed in to that same account. Built-in computer use follows GrowthBook `chicago_config.enabled` (logged at launch) on top of `preferences.chicagoEnabled`.
- Limit hits: when a request is refused, Claude Code writes `{"error":"rate_limit","apiErrorParams":{"rate_limit_info":{"resetsAt":<unix>,"rateLimitType":"five_hour"|"seven_day"}},"sessionId","cwd","timestamp"}` into the transcript. OpenAccs watches `~/.claude/projects`, reads new refusals, and gives each to the window whose Claude Code CLI runs that chat (`--resume=<id>`, else the one id-less CLI with that working folder; unsure → dropped). It belongs to the account that window showed then (a window that signs in to another account later doesn't take it along), and counts for every window of that account (the newest of each kind) until `resetsAt`, unless newer live numbers say otherwise; a window whose account isn't known gets none, and without live numbers a hit whose reset passed says nothing. Only refusals written while OpenAccs runs count (the last 2 minutes when it sees the change); nothing scans transcripts at launch.
- Each profile downloads its own Cowork VM (~12 GB). Show the disk cost when adding a profile.
- Sign-in in a new profile: `claude://` callbacks reach the oldest instance, so Google/SSO/email-link sign-in misroutes while another Claude is open. "Continue with email" + typing the 6-digit code works.

Claude limits (verified 2026-10-30)
- Read `sessionKey` only from the selected profile's `Cookies` or `Network/Cookies` SQLite database in read-only mode. Chromium v10 decryption uses the `Claude Safe Storage` / `Claude Key` Keychain item; version 24 validates the cookie host digest.
- `GET https://claude.ai/api/account` must match the profile's account UUID before `GET /api/organizations/<org>/usage`. The ephemeral HTTP session has no cookie storage or disk cache.
- Fetch once per account/org every five minutes and on explicit Refresh. Background reads never open a Keychain prompt. Failed requests preserve the age of the previous measurement; cached desktop history remains a dated fallback.
- The older Claude Code login helpers remain for compatibility but are no longer used by the panel or Refresh.

Codex
- The Codex desktop app is `/Applications/ChatGPT.app` (`com.openai.codex`). It and every `codex` CLI use `~/.codex/auth.json` (`{auth_mode, OPENAI_API_KEY, tokens:{id_token, access_token, refresh_token, account_id}, last_refresh}`). Identity from the id_token claims: `https://api.openai.com/auth.chatgpt_user_id` (or `user_id`), `tokens.account_id` (= `chatgpt_account_id`, the workspace), `email`, `chatgpt_plan_type`.
- Never swap the running app's sign-in. `NSWorkspace` opens additional instances with distinct `--user-data-dir`, `CODEX_HOME` and `CODEX_ELECTRON_USER_DATA_PATH`. Match an existing process by its data directory before launching.
- Profile homes use a short account hash under `~/.openaccs/codex/`; long paths exceed macOS's Unix socket path limit. `CODEX_SQLITE_HOME` points to the original `~/.codex`, with shared transcript folders and native writer locks. Never link individual SQLite or WAL files.
- Seed the project sidebar once, preserving existing preferences and remapping the local host identity. Later sidebar edits stay with each desktop process. Work configuration in the desktop's Configuration screen is account-specific server state, separate from shared `config.toml`.
- Local history is not split by account. Cloud tasks, connectors, chats and remote pairing follow the account.
- Refresh tokens rotate; **Log out / `codex logout` revokes them** and kills saved copies. Access tokens live 10 days.
- Refuse to create a profile if `~/.codex/config.toml` sets `cli_auth_credentials_store` to keyring/auto, or `~/.codex/secrets/` exists.
- Usage: `GET https://chatgpt.com/backend-api/wham/usage`, `Authorization: Bearer <access_token>`, `ChatGPT-Account-Id: <account_id>`. Classify windows by `limit_window_seconds` (18000 = 5h, 604800 = weekly), not by primary/secondary. `credits{has_credits, unlimited, balance}`, `rate_limit_reset_credits.available_count` = banked resets, `additional_rate_limits[]` = named windows, `spend_control.individual_limit{used_percent, reset_at}` = monthly when `rate_limit` is null.
- A managed profile owns its refresh token even while closed; OpenAccs only reads it. Refresh (parked vault accounts without a profile only): `POST https://auth.openai.com/oauth/token` JSON `{grant_type:"refresh_token", client_id:"app_EMoamEEZ73f0CkXaXp7hrann", refresh_token}` → new access/refresh/id tokens. Permanent failures (`refresh_token_expired|reused|invalidated`, 401, 400 invalid_grant) = needs sign-in.

Other limits
- Z.ai: `GET https://api.z.ai/api/monitor/usage/quota/limit` (CN: `https://open.bigmodel.cn/...`), `Authorization: <raw key>` (retry once with `Bearer ` on auth failure: HTTP 401 or JSON code 1000/1001). `data.level` = plan; `data.limits[]` `{type: TOKENS_LIMIT|CREDIT_LIMIT|TIME_LIMIT, unit, number, percentage, usage, currentValue, remaining, nextResetTime(ms)}`: unit 3 + number 5 = 5h, unit 6 = weekly, TIME_LIMIT unit 5 = monthly MCP. usedPercent = currentValue/usage when both exist, else percentage. HTTP 200 + code 500 "no coding plan" = no plan.
- Kimi Code: `GET https://api.kimi.com/coding/v1/usages` (global: `api.kimi.ai`), `Authorization: Bearer <Kimi Code API key>`. `usages.limit_5h|limit_7d|limit_month_total|limit_month_code` `{used_ratio 0–1, reset_time ISO}`; legacy `usage{limit, used, remaining, resetTime}` + `limits[{window{duration,timeUnit}, detail}]`. Plan: `GET .../me` → `user_level_name`. Wallet: `boosterWallet.balance.amountLeft` ÷ 1e6 = cents.
- Grok Bot (zero network): `~/Library/Application Support/Grok Bot/sand-client-persistence/<base32(lowercase, no padding) of "sand.client.slice.account.<account>.weekly-usage.cache">.blob` = `{schemaVersion:2, value:{kind:"present", reading:{usage:{percentUsed, nextResetMs, grokPlanLabel, isTeamSeat, onDemand}, readAtMs}, expiresAtMs}}`. Account keys: decode file names.
- Grok CLI (SuperGrok/Grok Build): OpenAccs-owned `GROK_HOME` per account, `grok login` once (binary `~/.grok/bin/grok`). Usage through the CLI so it owns token refresh: `GROK_HOME=<home> grok agent stdio` (JSON-RPC/ACP) → `initialize` → `_x.ai/billing` → `config.creditUsagePercent`, `currentPeriod{type WEEKLY|MONTHLY, start, end}`, `prepaidBalance.val` (USD cents), `subscriptionTier`. Low confidence; ship as experimental.

## Architecture

```
OpenAccs.app (SwiftUI MenuBarExtra, LSUIElement)
 ├─ App/        OpenAccsApp, AppModel (@Observable, @MainActor): accounts, usage, watchers, actions
 ├─ UI/         PanelView, AccountRow, Meter, AddAccountView, MenuBarIcon, snapshot mode
 └─ Packages/OpenAccsKit
     ├─ OpenAccsCore  Account, UsageSnapshot, Paths, AccountStore, SecretStore(Keychain), AtomicFile,
     │                ProcessRunner, LineProcess, ProcessList, FileWatcher, HTTPClient, JSON/JWT
     ├─ ClaudeKit     ClaudeProfiles, CardSync, TranscriptMigration, ClaudeDesktopUsage
     ├─ CodexKit      CodexAuthFile, CodexAccounts (vault, profiles, add, usage)
     └─ LimitsKit     ZaiUsage, KimiUsage, GrokBotUsage, GrokCLI
```

Storage
- `~/Library/Application Support/OpenAccs/accounts.json` — accounts (non-secret), `claude-sync.json` — sync state, `Backups/`, `Claude/<id>/Data` (a `Code` folder beside it is a 0.4.x sign-in), `Claude Code/<uuid>/` (one per Claude Code sign-in), `Grok/<id>/`.
- Keychain service `is.wai.openaccs`: `codex:<userId>:<accountId>` = full auth.json bytes; `apikey:<accountId>` = Z.ai/Kimi keys.

## ClaudeKit API

```swift
public struct ClaudeProfile: Sendable, Hashable {
    public var dataDir: URL; public var isDefault: Bool
    public var accountUuid: String?; public var orgUuid: String?
    public var cardsDir: URL?            // dataDir/claude-code-sessions/<acct>/<org>
}
public struct RunningClaude: Sendable, Hashable { public var pid: pid_t; public var dataDir: URL }
public struct DiscoveredClaudeProfile: Sendable, Hashable { public var dataDir: String?; public var label: String; public var legacyConfigDir: String? }

public struct ClaudeProfiles: Sendable {
    public init(paths: Paths)
    public func resolve(_ info: ClaudeAccountInfo) -> ClaudeProfile
    public func running() -> [RunningClaude]
    public func discover() -> [DiscoveredClaudeProfile]      // default + ~/.context-switcher-claude/profiles/*/desktop-data
    public func makeProfileDirectory(id: UUID) throws -> URL // <appSupport>/Claude/<id>/Data
    @MainActor public func open(_ profile: ClaudeProfile) async throws -> pid_t  // activate if running, else launch
    @MainActor public func quit(_ profile: ClaudeProfile, timeout: Duration) async -> Bool
}

public struct CardSync: Sendable {
    public init(paths: Paths)
    public func plan(profiles: [ClaudeProfile], running: Set<URL>) throws -> SyncPlan
    public func apply(_ plan: SyncPlan) throws -> SyncReport
    public func pendingCount(for profile: ClaudeProfile, among profiles: [ClaudeProfile]) -> Int
}

public enum TranscriptMigration {
    public static func run(from legacyConfigDir: URL, to sharedConfigDir: URL, backups: URL) throws -> MigrationReport
}
public enum AppSettings { public static func seed(_ dataDir: URL, from source: URL, pins: Bool) throws }   // synced by CardSync

public struct ClaudeCodeCLI: Sendable {
    public init(paths: Paths)
    public func executable() -> URL?
    public func configDir(for signIn: UUID) -> URL   // <appSupport>/Claude Code/<id>, a new one per sign-in, no trailing slash
    public func login(configDir: URL, email: String?, onLink: (URL) -> Void) async throws   // onLink once, while the CLI waits
    public func identity(configDir: URL) -> ClaudeCLIIdentity?   // email, organization, accountUuid, organizationUuid
    public func signIns(_ dirs: [String], for keys: Set<ClaudeAccountKey>) -> [ClaudeAccountKey: String]   // first folder per account and org
    public func sharing(_ who: ClaudeCLIIdentity, among windows: [(id: UUID, key: ClaudeAccountKey?, dir: String?)]) -> [UUID]
    public func usage(configDir: URL) async throws -> UsageSnapshot
    public static func privateWindowFlag(browser bundleID: String) -> String?
}
public struct ClaudeAccountKey: Hashable { public let account: String; public let org: String }   // lowercased
extension ClaudeProfile { public func limitsAccount(addedAs stored: String?) -> ClaudeAccountKey? }   // log, or the account it was added with
public enum ClaudeLimits {   // live for 30 minutes, else one line why
    public static func row(account: Bool, signIn: Bool, answer: UsageSnapshot?, problem: UsageError?, now: Date) -> Row   // usage, note, connect
}
```

Card sync rules
- Folders: every `<acct>/<org>` card folder of every profile. A profile's "current" folder is the one its app shows; it is "live" while that app runs. Other folders belong to accounts signed in there before and are never loaded while the app runs, so they can be edited at any time, but only when Claude's log confirmed which folder the app shows (`ClaudeProfile.isConfirmed`). With a guessed current folder, every folder of a running profile is live, and every edit in that profile re-checks right before writing that its app is still closed.
- Universe: cards in all folders that have a `cliSessionId` whose transcript exists under `~/.claude/projects/*/`.
- For each folder F and each session S not in F (no card with that cliSessionId) and not deleted anywhere (`deleted_<cliSessionId>` in any folder, or OpenAccs tombstone): create a card in F from the freshest copy (max `lastActivityAt`) through an allow-list: `sessionId, cliSessionId, cwd, originCwd, title, titleSource, createdAt, lastActivityAt, isArchived, isStarred, model, effort, permissionMode`, plus `completedTurns` if present, then the agreed chat settings (below). Keep the source `sessionId` unless that file name is taken in F (then `local_<new uuid>`). Exclusive create (`AtomicFile.createExclusively`), works for live folders too.
- For F not live: if F's card for S is older than the freshest copy, update `title, titleSource, lastActivityAt`; set the agreed chat settings (back up the old file first, unless only `lastActivityAt` changes). A title someone chose (`titleSource` `user` or `tool`) is never replaced.
- Chat settings (`isArchived`, `permissionMode` with `autoChosenInApp`/`bypassChosenInApp`, `effort`, `model`, Ultracode in `sessionSettings.ultracode`) are the same in every folder, three-way merged against what `claude-sync.json` saw in each folder last time: a folder whose value differs from what it held then changed it, and the newest such change (card mtime) wins; else the value agreed last time stays. A session never merged before is archived only when archived in every current folder, and takes the other settings from the copy used last: max `lastActivityAt`, then `lastFocusedAt`, then a card Claude wrote over one OpenAccs created, then the newest file (folders of accounts signed in earlier don't vote, unless no current folder has a value). `autoChosenInApp`/`bypassChosenInApp` always come from the card holding the agreed mode. Merge history is added to, never replaced by one scan; a deleted session's history is dropped. Live folders that differ count as changes in the pending caption ("4 changes") and catch up on the next restart; their old value is not a change of their own.
- Pins are not a card field the sidebar reads: it shows `preferences.epitaxyPrefs["starred-local-code-sessions"]` (card sessionIds) in each profile's `claude_desktop_config.json`, ordered by their place in `dframe-local-slice.pinnedOrder` (`code:<sessionId>`); Claude copies them into each card's `isStarred` itself. OpenAccs merges these lists per chat (cliSessionId) against `claude-sync.json` the same way: a pin or unpin since the last sync wins (the newest config on a conflict), a first sync or a new profile keeps every pin, and the order is the one of the profile changed last. A stopped profile gets the agreed list in the cards its current folder holds (or the card it already pins a chat by); ids that match no card stay. Only those two keys change, after the old ones are saved to Backups (never the rest of the file: MCP server settings can hold keys). An open profile writes its config from memory, so it counts the difference as changes until it restarts. A profile without a config yet is left alone.
- App settings are the same in every profile (ClaudeKit `AppSettings`, part of every sync, no switch): an allow-list of main-process preferences (no consent, opt-in, gate, seen or count flag), the folder permission modes (`epitaxy-folder-permission-mode-v2.<acct>`, each profile under its own account), the desktop chat MCP servers and the new-session defaults (under each profile's own account, only where the app made its presets). Merged per setting, and per entry for maps (a folder, a server), against `claude-sync.json` (digests only, never values: servers can hold keys): a profile that holds something else than it held at the last sync changed it, and the newest change wins (its file's date); otherwise the agreed value stays. The first sync takes the default profile's values and every entry only others have; a profile new to the sync never overrides anything and adds only entries nobody had. A setting a profile lacks is no opinion; a map entry it dropped is a removal. A stopped profile gets them in localStorage first (whole `LSS-persisted.*` values; inside the presets store, only `builtIns.local.settings`), then in the files, after the old values of what changes are saved to Backups; an open one counts what differs as changes until it restarts. A profile whose localStorage exists but can't be written is left alone; one that never ran gets the files only. A new profile's config is seeded from the default profile before its first launch.
- Cards without `cliSessionId` (right after `/clear`) still claim their `priorCliSessionIds`/`preClearCliSessionId`, so the cleared conversation is never re-created next to them.
- Deleted in one profile → in stopped profiles, move OpenAccs-created copies of that session to Backups (never hard-delete).
- Remember created files in `claude-sync.json` (so deletion detection and undo are possible).
- Each card is parsed once per file version (size, dates, inode) and kept in memory with only the allow-listed and settings fields. Claude writes account data into cards (`remoteMcpServersConfig` alone can be 600 KB, about 100 MB over a thousand cards); parsing all of it on every sync kept OpenAccs at 30% CPU while a chat was active. An edit reads the whole file again, only if it is still the version that was planned on.
- `pendingCount`: sessions in the universe that a running profile has not loaded (cards created after its launch, or missing). `plan.waiting(in:)`: what differs in a live folder (chats whose settings differ, pins with pin sync, app settings), shown as "N changes".
- Selecting a running profile only activates it. Pending sessions and settings load on the next explicit restart; the app never restarts a profile because its sidebar differs.

Moving an adopted profile onto `~/.claude`
- A profile with `legacyConfigDir` is left out of card sync while it runs. As soon as OpenAccs sees it fully stopped (main process and its bundled Claude Code CLIs gone, every Claude process identifiable), it imports `projects/` and `file-history/` from the old folder (copy-only; missing → copy, shorter shared copy → extend, diverged memory `.md` → merge lines, diverged `.jsonl` → the legacy file plus the shared-only lines, other differences → reported), then records the old folder as `migratedFrom` and syncs. If the profile started during the copy, nothing is marked; the next stop repeats it.
- `migratedFrom` is re-imported when the profile is stopped and the old folder changed since the last import (`importedFingerprint`: a hash of every file's path, size and date; recorded after each import, conflicts included, since an unchanged folder gives the same conflicts again), so a launch through an old launcher that still sets CLAUDE_CONFIG_DIR never strands sessions. Comparing unchanged folders on every sync (chats continued in `~/.claude` are longer there, so each was read in full) kept OpenAccs busy and delayed opening windows.
- `scripts/handoff-profile.sh` does the switch-over for a running profile: waits until it's idle, quits it, waits for OpenAccs, relaunches it without CLAUDE_CONFIG_DIR (or exactly as before if anything fails).
- One conversation open in two profiles at once means two writers on one transcript (they fork). Claude routes notification clicks to the oldest instance, which can open another profile's session. Avoid continuing the same session in two windows.

## CodexKit API

```swift
public enum CodexAuthFile { public static func identity(of authJSON: Data) -> CodexAccountInfo? }

public actor CodexAccounts {
    public init(paths: Paths, secrets: SecretStore, http: HTTPClient = URLSessionHTTPClient())
    public func liveIdentity() -> CodexAccountInfo?
    @discardableResult public func checkIn() throws -> CodexAccountInfo?   // live auth.json → vault slot
    public func hasVaultCopy(_ info: CodexAccountInfo) -> Bool
    public func processID(_ info: CodexAccountInfo) -> Int32?
    public func open(_ info: CodexAccountInfo, activate: Bool = true) async throws -> Int32
    public func switchTo(_ target: CodexAccountInfo) async throws          // legacy; not used by panel or CLI
    public func addAccount() async throws -> CodexAccountInfo              // `codex login` in a temp CODEX_HOME
    public func usage(_ info: CodexAccountInfo, refresh: Bool = true) async throws -> UsageSnapshot  // refresh: false never rotates tokens
    public func forget(_ info: CodexAccountInfo) throws                    // delete vault copy only, never log out
    public func otherHolders() -> [ProcessList.Entry]                      // codex processes the app didn't start (daemon excluded)
}
```

## LimitsKit API

```swift
public enum Region: String, Codable, Sendable { case global, china }
public struct ZaiUsage: Sendable  { public init(http: HTTPClient); public func fetch(apiKey: String, region: Region) async throws -> UsageSnapshot }
public struct KimiUsage: Sendable { public init(http: HTTPClient); public func fetch(apiKey: String, region: Region) async throws -> UsageSnapshot }
public struct GrokBotUsage: Sendable { public init(paths: Paths); public func accounts() -> [String]; public func read(account: String) -> UsageSnapshot? }
public struct GrokCLI: Sendable {
    public init(paths: Paths)
    public func executable() -> URL?
    public func home(for accountID: UUID) -> URL
    public func login(home: URL) async throws
    public func identity(home: URL) -> String?        // email from <home>/auth.json clear-text fields
    public func usage(home: URL) async throws -> UsageSnapshot
}
```

## UI

- `MenuBarExtra(.window)`, ~340 pt wide. Sections: **Claude**, **Codex**, then **Limits** (Grok, Kimi, Z.ai). Empty sections hidden.
- Row: color dot, label, Open/Closed status and plan. Meters show remaining limits and reset times. Orange at 20% left, red when empty. Old measurements fade and keep their timestamp; refresh failures appear on the same row. No separate "live" mode or Connect action.
- A small ✦ marks the account with the most left per product (least left across its main windows is highest; when every account is empty, the one back soonest); accounts that need sign-in never get it. Windows of one Claude account are scored once, and the ✦ goes on every window of the winner.
- Click: Claude and Codex activate the existing profile or launch it. Limits rows open the provider usage page.
- Running Claude profile with sessions it hasn't loaded: "3 new sessions · Restart" link; with other changes waiting, "4 changes · Restart".
- Setup starts with Instructions, Skills and Tools plus Review setup. Details holds file-level choices, permissions and history.
- Context menu: Rename, Color, Show data folder, Remove.
- Footer: Add account, Refresh (⌘R), Settings. Native Liquid Glass belongs to these controls; content stays calm.
- Menu-bar icon: a template glyph with two concentric rings = what's left of 5h (outer) and 7d (inner) of the Claude profile you used last. A full ring = untouched, a faint empty ring = out, a thin outline = no reading (also a window without live limits).
- `OpenAccs --snapshot <png> [--demo] [--dark] [--add <provider>]` renders the panel (or an add view) to a PNG and exits (for verification without clicking).

## Command line

- `openaccs` is the app's own executable in CLI mode: argv[0] is exactly `openaccs` (the app links `~/.local/bin/openaccs` to itself at launch when that folder exists, and only creates the link or repoints an older OpenAccs link), or argv[1] is `cli`. CLI mode runs before SwiftUI starts and never registers with LaunchServices.
- The CLI is a thin client. The running app serves one JSON line in, one JSON line out on `~/Library/Application Support/OpenAccs/control.sock` (folder 0700, socket 0600) and runs every command through the same AppModel actions as the panel. If the app isn't reachable, the CLI launches it in the background and waits up to 15 s.
- Commands: status/limits, best, use/switch/open, launch, restart, refresh, connect (legacy refresh alias), add, rename, remove, help, version. Accounts match by name, unique part, `provider:name` or the row number. `--json` prints a stable schema. Exit codes: 0 ok, 1 error, 2 usage, 3 not reachable.
- API keys for `add kimi|zai` come from stdin with `-` (or no key) and never appear in logs or child-process arguments.

- `status --json` includes the account's process ID and window IDs so orchestration can select the exact instance. `launch` is idempotent for both Claude and Codex and does not take focus.
