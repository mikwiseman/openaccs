# OpenAccs — design

*Switch accounts. Keep your work.*

A macOS menu-bar app for many AI accounts: Claude and Codex accounts you can switch between inside the desktop apps, with one shared history per product, plus usage limits for Claude, Codex, Grok, Kimi and Z.ai.

## Principles

1. **OpenAccs never touches Claude credentials.** No cookies, tokens, keychain items, decryption or copying of Claude logins. Each Claude account lives in its own Claude data folder ("profile"); OpenAccs only launches or activates Claude with `--user-data-dir`. Exact Claude limits come from running Anthropic's unmodified `claude` CLI, which holds its own login; OpenAccs only reads the CLI's answer. (Anthropic: third parties "may not collect, store, or intermediate Claude.ai credentials or session tokens".)
2. **One work environment per product.** Every Claude profile runs on the same `~/.claude` (CLAUDE_CONFIG_DIR unset): settings, skills, CLAUDE.md, MCP, memory and transcripts are shared. Codex keeps everything in `~/.codex`; a switch changes only `~/.codex/auth.json`.
3. **One popover.** Accounts grouped by product. Each row says who and how much is left. Click = switch.
4. **Never lose data.** Every write is atomic. Never edit a file a running app holds. Anything OpenAccs replaces or removes is copied to `~/Library/Application Support/OpenAccs/Backups/` first.

## Facts this design rests on (verified on this Mac, Claude 2.42304.2, Codex app 26.1013, codex-cli 0.163)

Claude desktop
- `--user-data-dir` works for the signed build; `CLAUDE_USER_DATA_DIR` is ignored. Launch extra profiles via LaunchServices with a new instance (`NSWorkspace.OpenConfiguration.createsNewApplicationInstance = true`, `arguments: ["--user-data-dir=<dir>"]`). The default profile is launched with no arguments.
- **No single-instance lock.** Two processes on one data folder corrupt it. OpenAccs must map running Claude main processes (bundle `com.anthropic.claudefordesktop`, argv without `--type=`) to their data folder and activate instead of launching twice.
- Instances look identical in Dock/⌘-Tab. OpenAccs is how you pick one.
- Code-tab session cards: `<dataDir>/claude-code-sessions/<accountUuid>/<orgUuid>/local_<uuid>.json`; file name must equal `sessionId + ".json"`. Account and org = the folder the app loaded last: latest `Loaded N persisted sessions from <dataDir>/claude-code-sessions/<acct>/<org>` line in `~/Library/Logs/Claude/main*.log`, else a folder of the account the profile was added with (recorded the first time the log names one), else the `<acct>/<org>` folder with the newest card. OpenAccs never opens `config.json` (it holds Claude's encrypted login caches).
- A profile keeps one card folder per account ever signed in there; the app reads a folder again when that account signs in (logout → login in the same window).
- **Cards are read only when the app initializes** (launch, sign-in, account/org switch). A running app never re-reads a card it holds and overwrites cards from memory. So: never edit or delete a card in a running profile. Creating a NEW card file (exclusive create) in a running profile is safe; it appears at the next launch.
- Transcripts: `<CLAUDE_CONFIG_DIR>/projects/<encoded-cwd>/<cliSessionId>.jsonl` (+ `<cliSessionId>/subagents/*.jsonl`). The desktop resumes with the card's `cliSessionId` and re-reads the transcript from disk, so a shared `~/.claude` shares content automatically.
- The Code tab authenticates with a token the desktop passes in the environment, never the CLI keychain item, so profiles on different accounts can share `~/.claude`. Leave CLAUDE_CONFIG_DIR unset (setting it to `~/.claude` explicitly changes which `.claude.json` is used).
- Never use symlinks or hard links for cards, card folders or transcripts (saves fail or files are refused). Never write temp files named `local_*.json.tmp` (the app promotes them).
- Deleting a session writes `deleted_<cliSessionId>` in that account folder.
- Account-bound card fields must never be copied: bridgeSessionIds, bridgeSessionId, cloudSessionId, movedToCloud, remoteControl*, steeredByRemoteClient, envScopeId, remoteMcpServersConfig, withheldConnectorHosts, enabledMcpTools, scheduledTaskId, startedFromEnvironmentId, emailAddress, worktreePath, worktreeName, branch, folderWorktrees, keptDirtyWorktree, worktreeLazy, stagedTranscriptPath, importedFrom, resumeConfirmed, peerReceipts, peerInbound, peerMessaged, spawnedFrom, dispatchParent*, forkedFromSessionId, sessionPermissionUpdates, alwaysAllowedReasons, cuAllowedApps, cuGrantFlags, chromeAllowedDomains, spawnSeed, sshRemoteProcessId, pendingSystemReminder, spaceId, publishedArtifacts.
- `<dataDir>/plan-usage-history.json` = `{version:2, samples:[{t (ms), org, u:{fh (5h %), sd (7d %), so, sn, oa, cw, om, op, xu}}]}`, appended by the desktop only now and then (seen: at launch and quit, not during normal use). No reset times. Credential-free. Shown only while under 15 minutes old; older numbers aren't today's limits, so the row offers exact limits instead. Exact limits refresh every 5 minutes.
- Each profile downloads its own Cowork VM (~12 GB). Show the disk cost when adding a profile.
- Sign-in in a new profile: `claude://` callbacks reach the oldest instance, so Google/SSO/email-link sign-in misroutes while another Claude is open. "Continue with email" + typing the 6-digit code works.

Claude Code CLI (exact limits)
- `claude -p --input-format stream-json --output-format stream-json --verbose --no-session-persistence`, then send `{"type":"control_request","request_id":"u","request":{"subtype":"get_usage","skip_behaviors":true}}` → `{"type":"control_response","response":{"subtype":"success","request_id":"u","response":{subscription_type, rate_limits_available, rate_limits:{five_hour, seven_day, seven_day_opus, seven_day_sonnet, seven_day_oauth_apps, model_scoped:[{display_name, utilization, resets_at}], extra_usage:{is_enabled, monthly_limit, used_credits, utilization, currency}}}}}`. Answers in <1 s; verified with a logged-out config dir (`rate_limits_available:false`). The CLI refreshes its own token under its own lock.
- Each Claude account that wants exact limits gets an OpenAccs-owned CLAUDE_CONFIG_DIR `~/Library/Application Support/OpenAccs/Claude/<id>/Code` signed in once with `claude auth login --claudeai [--email <e>]` (Anthropic's own browser flow). The CLI stores its login in keychain item `Claude Code-credentials-<sha256(dir)[:8]>`; OpenAccs never reads it. Identity: `<dir>/.claude.json` → `oauthAccount.emailAddress`, `organizationName`.
- CLI binary: `~/.local/bin/claude` (symlink to `~/.local/share/claude/versions/<v>`), else the newest desktop-bundled `<defaultDataDir>/claude-code/<v>/<hash>/claude.app/Contents/MacOS/claude`. Never a `claude` under `~/.codex` (wrappers there are not the real CLI). Run with a clean environment (no CLAUDE_*/ANTHROPIC_*), cwd = a neutral folder.

Codex
- The Codex desktop app is `/Applications/ChatGPT.app` (`com.openai.codex`). It and every `codex` CLI use `~/.codex/auth.json` (`{auth_mode, OPENAI_API_KEY, tokens:{id_token, access_token, refresh_token, account_id}, last_refresh}`). Identity from the id_token claims: `https://api.openai.com/auth.chatgpt_user_id` (or `user_id`), `tokens.account_id` (= `chatgpt_account_id`, the workspace), `email`, `chatgpt_plan_type`.
- A running app-server never adopts a swapped auth.json (it keeps the old account in memory). A switch = quit the app, swap, relaunch.
- Local history is not split by account. Cloud tasks, connectors, chats and remote pairing follow the account.
- Refresh tokens rotate; **Log out / `codex logout` revokes them** and kills saved copies. Access tokens live 10 days.
- Refuse to switch if `~/.codex/config.toml` sets `cli_auth_credentials_store` to keyring/auto, or `~/.codex/secrets/` exists.
- Usage: `GET https://chatgpt.com/backend-api/wham/usage`, `Authorization: Bearer <access_token>`, `ChatGPT-Account-Id: <account_id>`. Classify windows by `limit_window_seconds` (18000 = 5h, 604800 = weekly), not by primary/secondary. `credits{has_credits, unlimited, balance}`, `rate_limit_reset_credits.available_count` = banked resets, `additional_rate_limits[]` = named windows, `spend_control.individual_limit{used_percent, reset_at}` = monthly when `rate_limit` is null.
- Refresh (parked vault accounts only): `POST https://auth.openai.com/oauth/token` JSON `{grant_type:"refresh_token", client_id:"app_EMoamEEZ73f0CkXaXp7hrann", refresh_token}` → new access/refresh/id tokens. Permanent failures (`refresh_token_expired|reused|invalidated`, 401, 400 invalid_grant) = needs sign-in.

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
     ├─ ClaudeKit     ClaudeProfiles, CardSync, TranscriptMigration, ClaudeAppUsage, ClaudeCodeCLI
     ├─ CodexKit      CodexAuthFile, CodexAccounts (vault, check-in, switch, add, usage)
     └─ LimitsKit     ZaiUsage, KimiUsage, GrokBotUsage, GrokCLI
```

Storage
- `~/Library/Application Support/OpenAccs/accounts.json` — accounts (non-secret), `claude-sync.json` — sync state, `Backups/`, `Claude/<id>/{Data,Code}`, `Grok/<id>/`.
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
public enum ClaudeAppUsage { public static func read(profile: ClaudeProfile) -> UsageSnapshot? }

public struct ClaudeCodeCLI: Sendable {
    public init(paths: Paths)
    public func executable() -> URL?
    public func configDir(for accountID: UUID) -> URL   // <appSupport>/Claude/<id>/Code, no trailing slash
    public func login(configDir: URL, email: String?) async throws
    public func identity(configDir: URL) -> ClaudeCLIIdentity?   // email, organization, accountUuid
    public func usage(configDir: URL) async throws -> UsageSnapshot
}
```

Card sync rules
- Folders: every `<acct>/<org>` card folder of every profile. A profile's "current" folder is the one its app shows; it is "live" while that app runs. Other folders belong to accounts signed in there before and are never loaded while the app runs, so they can be edited at any time, but only when Claude's log confirmed which folder the app shows (`ClaudeProfile.isConfirmed`). With a guessed current folder, every folder of a running profile is live, and every edit in that profile re-checks right before writing that its app is still closed.
- Universe: cards in all folders that have a `cliSessionId` whose transcript exists under `~/.claude/projects/*/`.
- For each folder F and each session S not in F (no card with that cliSessionId) and not deleted anywhere (`deleted_<cliSessionId>` in any folder, or OpenAccs tombstone): create a card in F from the freshest copy (max `lastActivityAt`) through an allow-list: `sessionId, cliSessionId, cwd, originCwd, title, titleSource, createdAt, lastActivityAt, isArchived, isStarred, model, effort, permissionMode`, plus `completedTurns` if present, then the agreed chat settings (below). Keep the source `sessionId` unless that file name is taken in F (then `local_<new uuid>`). Exclusive create (`AtomicFile.createExclusively`), works for live folders too.
- For F not live: if F's card for S is older than the freshest copy, update `title, titleSource, lastActivityAt`; set the agreed chat settings (back up the old file first, unless only `lastActivityAt` changes). A title someone chose (`titleSource` `user` or `tool`) is never replaced.
- Chat settings (`isStarred`, `isArchived`, `permissionMode` with `autoChosenInApp`/`bypassChosenInApp`, `effort`, `model`) are the same in every folder, three-way merged against what `claude-sync.json` saw in each folder last time: a folder whose value differs from what it held then changed it, and the newest such change (card mtime) wins; else the value agreed last time stays. A session never merged before keeps every pin a current folder has, is archived only when archived in every current folder, and takes the other settings from the copy used last: max `lastActivityAt`, then `lastFocusedAt`, then a card Claude wrote over one OpenAccs created, then the newest file (folders of accounts signed in earlier don't vote, unless no current folder has a value). `autoChosenInApp`/`bypassChosenInApp` always come from the card holding the agreed mode. Merge history is added to, never replaced by one scan; a deleted session's history is dropped. Live folders that differ count as "changed" in the pending caption and catch up on the next restart; their old value is not a change of their own.
- Cards without `cliSessionId` (right after `/clear`) still claim their `priorCliSessionIds`/`preClearCliSessionId`, so the cleared conversation is never re-created next to them.
- Deleted in one profile → in stopped profiles, move OpenAccs-created copies of that session to Backups (never hard-delete).
- Remember created files in `claude-sync.json` (so deletion detection and undo are possible).
- `pendingCount`: sessions in the universe that a running profile has not loaded (cards created after its launch, or missing). `plan.waiting(in:)`: chats in a live folder whose settings differ from the agreed ones.
- Switching to a running profile with something pending restarts it when it is idle (never a profile still on its own config folder): every Claude Code CLI under its window (`…/claude-code/…/MacOS/claude`) has a `--resume=<id>` whose newest transcript copy ends with a finished assistant turn (`end_turn`, `stop_sequence`, `max_tokens`, `refusal`, main thread only) that started nothing that keeps running (`ScheduleWakeup`, `CronCreate`, `Workflow`, `Monitor`, an `Agent`/`Task` with `run_in_background`); no CLI has a shell child (a command or background task); and no terminal-tab shell under the window has a child (a job). Anything unknown counts as busy; then it only comes forward. `pendingCount` scans the same folders as `plan`.

Moving an adopted profile onto `~/.claude`
- A profile with `legacyConfigDir` is left out of card sync while it runs. As soon as OpenAccs sees it fully stopped (main process and its bundled Claude Code CLIs gone, every Claude process identifiable), it imports `projects/` and `file-history/` from the old folder (copy-only; missing → copy, shorter shared copy → extend, diverged memory `.md` → merge lines, diverged `.jsonl` → the legacy file plus the shared-only lines, other differences → reported), then records the old folder as `migratedFrom` and syncs. If the profile started during the copy, nothing is marked; the next stop repeats it.
- `migratedFrom` is re-imported on every stop (fast: same size + date is skipped unread), so a launch through an old launcher that still sets CLAUDE_CONFIG_DIR never strands sessions.
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
    public func switchTo(_ target: CodexAccountInfo) async throws          // quit → check-in → swap → relaunch → verify
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
- Row: color dot (filled = running/active, ring = idle) · label · plan chip. Below: one meter per main window (5h, 7d, month) showing what's LEFT: the bar is the remaining amount (full = untouched), "62% left", and the reset ("2h 10m", "Thu"). An empty window has no bar: "Empty · back in 1h 12m", the strongest thing in the row. Calm gray while plenty is left, orange at 20% left or less, red only when empty. A caption line for credits / banked resets / "updated 2h ago" when older than 30 minutes (the numbers fade). A window whose reset time has passed shows full until the next reading. The list scrolls past 680 pt, and a confirmation opened near its edge scrolls into view.
- A small ✦ marks the account with the most left per product (least left across its main windows is highest; when every account is empty, the one back soonest); accounts that need sign-in never get it.
- Click: Claude → open that profile (activate or launch). Codex → inline confirm "Restart Codex as …?" then switch. Limits rows → provider usage page.
- Running Claude profile with sessions it hasn't loaded: "3 new sessions · Restart" link.
- Context menu: Rename, Color, Connect exact limits (Claude), Show data folder, Remove.
- Footer: "+ Add" menu (Claude, Codex, Grok, Kimi, Z.ai) and "⋯" (Refresh, Launch at login, Quit).
- Menu-bar icon: a template glyph with two concentric rings = what's left of 5h (outer) and 7d (inner) of the Claude profile you used last. A full ring = untouched, a faint empty ring = out, a thin outline = no reading.
- `OpenAccs --snapshot <png> [--demo] [--dark]` renders the panel to a PNG and exits (for verification without clicking).

## Command line

- `openaccs` is the app's own executable in CLI mode: argv[0] is exactly `openaccs` (the app links `~/.local/bin/openaccs` to itself at launch when that folder exists, and only creates the link or repoints an older OpenAccs link), or argv[1] is `cli`. CLI mode runs before SwiftUI starts and never registers with LaunchServices.
- The CLI is a thin client. The running app serves one JSON line in, one JSON line out on `~/Library/Application Support/OpenAccs/control.sock` (folder 0700, socket 0600) and runs every command through the same AppModel actions as the panel. If the app isn't reachable, the CLI launches it in the background and waits up to 15 s.
- Commands: status/limits, best, use/switch/open (Codex asks y/N on a TTY, refuses without `--yes` otherwise), restart, refresh, connect, add, rename, remove, help, version. Accounts match by name, unique part, `provider:name` or the row number. `--json` prints a stable schema. Exit codes: 0 ok, 1 error, 2 usage, 3 not reachable.
- API keys for `add kimi|zai` come from stdin with `-` (or no key) and never appear in logs or child-process arguments.
