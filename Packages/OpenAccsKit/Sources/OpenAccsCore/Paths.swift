import Foundation

/// Every on-disk location OpenAccs reads or writes. Tests pass a temporary `home`.
public struct Paths: Sendable, Hashable {
    public var home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
    }

    public var appSupport: URL { home.appending(path: "Library/Application Support/OpenAccs", directoryHint: .isDirectory) }
    public var accountsFile: URL { appSupport.appending(path: "accounts.json") }
    public var syncStateFile: URL { appSupport.appending(path: "claude-sync.json") }
    public var backupsDir: URL { appSupport.appending(path: "Backups", directoryHint: .isDirectory) }
    /// New Claude profiles: `<claudeProfilesDir>/<uuid>/Data` (desktop) and `.../Code` (CLI for limits).
    public var claudeProfilesDir: URL { appSupport.appending(path: "Claude", directoryHint: .isDirectory) }
    public var grokHomesDir: URL { appSupport.appending(path: "Grok", directoryHint: .isDirectory) }

    // Claude desktop
    public var claudeApp: URL { URL(filePath: "/Applications/Claude.app", directoryHint: .isDirectory) }
    public var claudeDefaultDataDir: URL { home.appending(path: "Library/Application Support/Claude", directoryHint: .isDirectory) }
    /// Shared Claude Code folder for every profile (CLAUDE_CONFIG_DIR left unset).
    public var claudeSharedConfigDir: URL { home.appending(path: ".claude", directoryHint: .isDirectory) }
    public var claudeLogsDir: URL { home.appending(path: "Library/Logs/Claude", directoryHint: .isDirectory) }
    public var contextSwitcherProfilesDir: URL { home.appending(path: ".context-switcher-claude/profiles", directoryHint: .isDirectory) }
    public var claudeProfileLaunchersDir: URL { home.appending(path: "Applications/Claude Profiles", directoryHint: .isDirectory) }

    // Codex
    public var codexApp: URL { URL(filePath: "/Applications/ChatGPT.app", directoryHint: .isDirectory) }
    public var codexHome: URL { home.appending(path: ".codex", directoryHint: .isDirectory) }
    public var codexAuthFile: URL { codexHome.appending(path: "auth.json") }

    // Grok
    public var grokBotPersistenceDir: URL { home.appending(path: "Library/Application Support/Grok Bot/sand-client-persistence", directoryHint: .isDirectory) }
    public var grokCLIHome: URL { home.appending(path: ".grok", directoryHint: .isDirectory) }
}

public enum BundleIDs {
    public static let claude = "com.anthropic.claudefordesktop"
    public static let codex = "com.openai.codex"
}
