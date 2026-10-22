import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude, codex, grok, kimi, zai

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .kimi: "Kimi"
        case .zai: "Z.ai"
        }
    }
}

/// One account the user added. Non-secret; persisted in accounts.json.
/// Secrets (API keys, Codex auth.json snapshots) live in the Keychain, keyed by `id`.
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var label: String
    public var color: Int
    public var createdAt: Date
    public var claude: ClaudeAccountInfo?
    public var codex: CodexAccountInfo?
    public var apiKey: APIKeyAccountInfo?
    public var grok: GrokAccountInfo?

    public init(
        id: UUID = UUID(), provider: Provider, label: String, color: Int = 0, createdAt: Date = Date(),
        claude: ClaudeAccountInfo? = nil, codex: CodexAccountInfo? = nil,
        apiKey: APIKeyAccountInfo? = nil, grok: GrokAccountInfo? = nil
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.color = color
        self.createdAt = createdAt
        self.claude = claude
        self.codex = codex
        self.apiKey = apiKey
        self.grok = grok
    }
}

/// A Claude account is a Claude desktop data folder ("profile"). OpenAccs never touches its login.
public struct ClaudeAccountInfo: Codable, Hashable, Sendable {
    /// Absolute path of the Claude data folder (`--user-data-dir`). nil = the default
    /// `~/Library/Application Support/Claude`, launched without arguments.
    public var dataDir: String?
    /// A CLAUDE_CONFIG_DIR this profile used before OpenAccs (adopted profiles). Its transcripts are
    /// imported into the shared `~/.claude` once, then the profile runs on the shared folder.
    public var legacyConfigDir: String?
    /// The old CLAUDE_CONFIG_DIR after the move. Re-imported (copy-only, idempotent) whenever the profile
    /// stops, so a launch through an old launcher that still uses it never strands sessions there.
    public var migratedFrom: String?
    /// OpenAccs-owned CLAUDE_CONFIG_DIR where the official Claude Code CLI is signed in for this
    /// account, used only to ask the CLI for exact limits. nil = not connected.
    public var cliConfigDir: String?
    /// Last account UUID seen for this profile (from Claude's log or card folders; never config.json).
    public var accountUuid: String?
    /// The old config folder as it was at its last import (`TranscriptMigration.fingerprint`): unchanged
    /// means nothing new to import.
    public var importedFingerprint: String?

    public init(dataDir: String? = nil, legacyConfigDir: String? = nil, cliConfigDir: String? = nil, accountUuid: String? = nil) {
        self.dataDir = dataDir
        self.legacyConfigDir = legacyConfigDir
        self.cliConfigDir = cliConfigDir
        self.accountUuid = accountUuid
    }
}

/// A ChatGPT login used by Codex. The full auth.json lives in the Keychain under the account id.
public struct CodexAccountInfo: Codable, Hashable, Sendable {
    public var userId: String
    public var accountId: String
    public var email: String?
    public var plan: String?

    public init(userId: String, accountId: String, email: String? = nil, plan: String? = nil) {
        self.userId = userId
        self.accountId = accountId
        self.email = email
        self.plan = plan
    }
}

/// Z.ai / Kimi: an API key (in the Keychain) plus its region.
public struct APIKeyAccountInfo: Codable, Hashable, Sendable {
    public var region: String

    public init(region: String) { self.region = region }
}

public struct GrokAccountInfo: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Official Grok Build CLI signed in inside an OpenAccs-owned GROK_HOME.
        case cli
        /// Grok Bot app's local weekly-usage cache (read-only, no network).
        case grokBot
    }

    public var source: Source
    /// GROK_HOME for `.cli`.
    public var home: String?
    /// Grok Bot account key (e.g. `google-oauth2|user_…`) for `.grokBot`.
    public var botAccount: String?

    public init(source: Source, home: String? = nil, botAccount: String? = nil) {
        self.source = source
        self.home = home
        self.botAccount = botAccount
    }
}
