import AppKit
import ClaudeKit
import Foundation
import OpenAccsCore
import SetupKit

/// One setup on this Mac: the context OpenAccs's own accounts give, for the Settings window and `openaccs setup`.
enum SetupService {
    /// Claude profiles come from accounts.json (the one used last first), each with the account its app shows.
    static func context(paths: Paths = .current, lastClaude: UUID? = nil) -> SetupContext {
        let accounts = (try? AccountStore(file: paths.accountsFile).load()) ?? []
        var claude = accounts.filter { $0.provider == .claude && $0.claude != nil && $0.claude?.legacyConfigDir == nil }
        if let lastClaude = lastClaude ?? savedLastClaude(), let i = claude.firstIndex(where: { $0.id == lastClaude }) {
            claude.insert(claude.remove(at: i), at: 0)
        }
        let profiles = ClaudeProfiles(paths: paths)
        let resolved = claude.compactMap(\.claude).map(profiles.resolve)
        let cli = ClaudeCodeCLI(paths: paths).executable()
        return SetupContext(
            home: paths.home,
            claudeProfiles: resolved.map { ClaudeProfileRef(dataDir: $0.dataDir, accountUuid: $0.accountUuid) },
            isRunning: { app in
                switch app {
                case .chatGPT:
                    !NSRunningApplication.runningApplications(withBundleIdentifier: BundleIDs.codex).isEmpty
                case .claude(let dir):
                    // Unknown processes, and a profile accounts.json no longer lists, count as "maybe this one":
                    // a running app's file is never written.
                    resolved.first { $0.dataDir.standardizedFileURL.path == URL(filePath: dir).standardizedFileURL.path }
                        .map(profiles.mayBeRunning) ?? true
                }
            },
            run: { argv in run(argv, claude: cli, home: paths.home) }
        )
    }

    /// The Claude profile used last, as the app saves it. Read from the app's own domain, since `openaccs` run
    /// through its link has another one; so the Settings window and the CLI order profiles the same way.
    static func savedLastClaude() -> UUID? {
        let domain = Paths.isOverridden ? "is.wai.openaccs.test" : "is.wai.openaccs"
        let defaults = Bundle.main.bundleIdentifier == domain ? .standard : UserDefaults(suiteName: domain)
        return defaults?.string(forKey: "lastClaude").flatMap(UUID.init)
    }

    /// Runs a tool by name (`claude`, `codex`, `sqlite3`) or path, with no account variables and the home as its
    /// folder; waits up to three minutes (a merge by `claude -p` takes a while), then stops it and gives status -1.
    static func run(_ argv: [String], claude: URL?, home: URL) -> (status: Int32, output: String)? {
        guard let name = argv.first else { return nil }
        // A debug fixture must never invoke a CLI that writes the user's real home.
        if home.standardizedFileURL != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
           name == "claude" || name == "codex" { return nil }
        let executable: URL? = switch name {
        case "claude": claude
        case "codex": URL(filePath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        case "sqlite3": URL(filePath: "/usr/bin/sqlite3")
        default: name.hasPrefix("/") ? URL(filePath: name) : nil
        }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = Array(argv.dropFirst())
        process.environment = ProcessRunner.cleanEnvironment()
        process.currentDirectoryURL = home
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + .seconds(180)
        let reading = DispatchQueue.global()
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        reading.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return (-1, "")
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// `openaccs setup --json`: what was read and what would change, without file contents.
struct SetupSummary: Encodable {
    struct Change: Encodable {
        var id: String
        var title: String
        var detail: String?
        var waitsFor: String?
    }

    var area: String
    var summary: String
    var attention: [Attention]
    var changes: [Change]
    var items: [SetupItem]

    init(_ report: AreaReport) {
        area = report.area.rawValue
        summary = report.summary
        attention = report.attention
        changes = report.changes.map { change in
            let waits: String? = switch change.waitsFor {
            case .chatGPT: "ChatGPT"
            case .claude(let dir): dir
            case nil: nil
            }
            return Change(id: change.id, title: change.title, detail: change.detail, waitsFor: waits)
        }
        items = report.items
    }
}
