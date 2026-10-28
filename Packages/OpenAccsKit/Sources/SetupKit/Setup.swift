import Foundation
import OpenAccsCore

/// One setup: the same instructions, skills, MCP servers and settings for every Claude profile and Codex.
/// Each area reads what is on disk (never writes while scanning) and proposes changes; nothing changes until
/// the user applies a plan, and every applied change can be undone from History.
///
/// Rules every area follows:
/// - One source for each thing, placed where each tool already reads it; link where links work, translate
///   only where the formats differ (MCP), never rewrite a word inside a file.
/// - Logins, tokens, keys written into files, account-bound data and machine state are never copied.
/// - A file a running app keeps in memory is written only while that app is closed (`waitsFor`).
public enum SetupArea: String, CaseIterable, Codable, Sendable, Hashable {
    /// `claudeApp` is scanned no more (the Claude sync keeps those settings the same); History may still hold its changes.
    case instructions, skills, mcp, claudeApp, defaults, importSync

    public var title: String {
        switch self {
        case .instructions: "Instructions"
        case .skills: "Skills"
        case .mcp: "MCP servers"
        case .claudeApp: "Claude app"
        case .defaults: "Defaults"
        case .importSync: "ChatGPT Import"
        }
    }
}

/// An app whose files may be written only while it is closed.
public enum SetupApp: Codable, Sendable, Hashable {
    /// The ChatGPT app (Codex): it keeps ~/.codex/config.toml in memory.
    case chatGPT
    /// A Claude desktop profile, by its data folder path.
    case claude(String)
}

/// A Claude desktop profile: its `--user-data-dir` folder and the account its app shows, if known.
public struct ClaudeProfileRef: Codable, Sendable, Hashable {
    public var dataDir: URL
    public var accountUuid: String?
    public init(dataDir: URL, accountUuid: String? = nil) {
        self.dataDir = dataDir.standardizedFileURL
        self.accountUuid = accountUuid
    }
}

/// Where One setup looks and what it may run. Tests pass a temporary home and fakes.
public struct SetupContext: Sendable {
    public var home: URL
    /// Claude desktop profiles, the one used last first.
    public var claudeProfiles: [ClaudeProfileRef]
    public var isRunning: @Sendable (SetupApp) -> Bool
    /// Runs a command line tool (argv) and returns its exit status and output; nil if it can't start.
    public var run: @Sendable ([String]) -> (status: Int32, output: String)?
    public var paths: Paths { Paths(home: home) }

    public init(home: URL, claudeProfiles: [ClaudeProfileRef], isRunning: @escaping @Sendable (SetupApp) -> Bool,
                run: @escaping @Sendable ([String]) -> (status: Int32, output: String)?) {
        self.home = home.standardizedFileURL
        self.claudeProfiles = claudeProfiles
        self.isRunning = isRunning
        self.run = run
    }

    public func url(_ relative: String) -> URL { home.appending(path: relative) }
}

/// What one area found: a sentence for its row, what needs the user, the changes Apply would make, and the
/// items behind the counts. Every sentence describes what was read from the files, never what was written.
public struct AreaReport: Codable, Sendable, Hashable {
    public var area: SetupArea
    public var summary: String
    public var attention: [Attention] = []
    public var changes: [SetupChange] = []
    public var items: [SetupItem] = []

    public init(area: SetupArea, summary: String, attention: [Attention] = [], changes: [SetupChange] = [], items: [SetupItem] = []) {
        self.area = area
        self.summary = summary
        self.attention = attention
        self.changes = changes
        self.items = items
    }
}

public struct Attention: Codable, Sendable, Hashable, Identifiable {
    public enum Level: String, Codable, Sendable { case needsYou, broken }
    public var id: String
    public var text: String
    public var level: Level = .needsYou
    /// The changes (by id) that resolve it, if Apply can.
    public var fixes: [String] = []

    public init(id: String, text: String, level: Level = .needsYou, fixes: [String] = []) {
        self.id = id
        self.text = text
        self.level = level
        self.fixes = fixes
    }
}

/// One row in an area's detail table: where an item is present.
public struct SetupItem: Codable, Sendable, Hashable, Identifiable {
    public enum Presence: String, Codable, Sendable { case same, differs, waiting, missing, notShared }
    public var id: String
    public var name: String
    public var claude: Presence
    public var codex: Presence
    public var note: String?

    public init(id: String, name: String, claude: Presence, codex: Presence, note: String? = nil) {
        self.id = id
        self.name = name
        self.claude = claude
        self.codex = codex
        self.note = note
    }
}

/// One change Apply can make, as file operations planned against what was read.
public struct SetupChange: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var area: SetupArea
    public var title: String
    /// A diff or an explanation shown before applying.
    public var detail: String?
    public var operations: [FileOperation]
    /// Apply skips it while this app runs (and says so).
    public var waitsFor: SetupApp?
    /// Changes (by id) that must apply in the same run first, or this one would leave things broken.
    public var requires: [String]

    public init(id: String, area: SetupArea, title: String, detail: String? = nil, operations: [FileOperation],
                waitsFor: SetupApp? = nil, requires: [String] = []) {
        self.id = id
        self.area = area
        self.title = title
        self.detail = detail
        self.operations = operations
        self.waitsFor = waitsFor
        self.requires = requires
    }
}

/// A file operation. Each carries what the path held when it was planned; Apply does nothing if that changed.
public enum FileOperation: Codable, Sendable, Hashable {
    /// Edit one TOML key or MCP table, checking that value and keeping unrelated edits from other areas.
    case toml(path: String, table: [String], key: String, value: TOMLValue?, expected: TOMLValue?)
    /// Set one top-level key of a JSON object file (values as JSON text; nil: not there), checking that key's value
    /// and keeping every other key, which the file's own tool may have changed since.
    case json(path: String, key: String, value: String, expected: String?)
    /// One user-scope Claude MCP server, changed through Claude's CLI and checked before Apply and Undo.
    case claudeMCP(name: String, value: String?, expected: String?)
    /// Create or replace a file atomically.
    case write(path: String, contents: Data, permissions: Int = 0o600, expected: FileState)
    /// Make `path` a symbolic link to `target`.
    case link(path: String, target: String, expected: FileState)
    /// Move a file, folder or link to Backups.
    case remove(path: String, expected: FileState)
    /// Move a file, folder or link to `destination`, where nothing is.
    case move(path: String, destination: String, expected: FileState)
    /// Run a tool that owns its own file (like `claude mcp add-json`), with the command that reverses it.
    case command(argv: [String], undo: [String])
    /// History only: put a backed-up file, folder or link back at `path`.
    case restore(path: String, backup: String, expected: FileState)
}

/// What a path holds, enough to tell whether it changed.
public enum FileState: Codable, Sendable, Hashable {
    case absent
    case file(sha256: String)
    case link(target: String)
    case folder

    public static func of(_ url: URL) -> FileState {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .absent }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .link(target: (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "")
        case S_IFDIR: return .folder
        default: return .file(sha256: Digest.sha256((try? Data(contentsOf: url)) ?? Data()))
        }
    }
}

public extension FileState {
    /// A file holding exactly these bytes.
    static func file(contents: Data) -> FileState { .file(sha256: Digest.sha256(contents)) }
}
