import Foundation
import OpenAccsCore
import Testing
@testable import ClaudeKit

@Suite struct ClaudeProfilesTests {
    let acct = "11111111-1111-4111-8111-111111111111"
    let orgA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let orgB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let acct2 = "5f0c1d2e-3b4a-4c5d-8e6f-7a8b9c0d1e2f"

    @Test func resolvesAccountAndOrgFromTheLatestLogLineAndNeverConfigJSON() throws {
        let home = try TempHome()
        let data = home.paths.claudeDefaultDataDir
        // config.json holds Claude's login caches; its account must play no part.
        try home.writeJSON("Library/Application Support/Claude/config.json", ["lastKnownAccountUuid": acct, "oauth:tokenCache": "x"])
        let other = "/Users/x/.context-switcher-claude/profiles/p/desktop-data/claude-code-sessions/\(acct)/\(orgB)"
        try home.write("Library/Logs/Claude/main1.log", "2026-10-19 10:00:00 [info] Loaded 3 persisted sessions from \(data.path)/claude-code-sessions/\(acct)/\(orgB)\n")
        try home.write("Library/Logs/Claude/main.log", """
            2026-10-20 07:00:00 [info] Loaded 0 persisted sessions from \(data.path)/local-agent-mode-sessions/\(acct)/\(orgB)
            2026-10-20 07:01:00 [info] Loaded 154 persisted sessions from \(data.path)/claude-code-sessions/\(acct)/\(orgA) (2 archived deferred, 2 of them unopened; hint used)
            2026-10-20 07:02:00 [info] Loaded 1 persisted sessions from \(data.path)/claude-code-sessions/\(acct2)/\(orgA)
            2026-10-20 07:03:00 [info] Loaded 9 persisted sessions from \(other)

            """)

        let profile = ClaudeProfiles(paths: home.paths, processes: { [] }).resolve(ClaudeAccountInfo(accountUuid: acct))

        #expect(profile.isDefault)
        #expect(profile.dataDir.path == data.path)
        #expect(profile.accountUuid == acct2)  // the user switched accounts in this profile
        #expect(profile.orgUuid == orgA)
        #expect(profile.cardsDir?.path == "\(data.path)/claude-code-sessions/\(acct2)/\(orgA)")
    }

    @Test func logOnlyCountsItsTail() throws {
        let home = try TempHome()
        let data = home.url.appending(path: "Profiles/p/Data", directoryHint: .isDirectory)
        let line = "Loaded 1 persisted sessions from \(data.path)/claude-code-sessions/\(acct)/\(orgA)\n"
        try home.write("Library/Logs/Claude/main.log", line + String(repeating: "x", count: 4 << 20) + "\n")
        try home.write("Profiles/p/Data/claude-code-sessions/\(acct)/\(orgB)/local_a.json", "{}")

        let profile = ClaudeProfiles(paths: home.paths, processes: { [] }).resolve(ClaudeAccountInfo(dataDir: data.path))

        // The old line is out of reach; falls back to the folder with cards.
        #expect(profile.accountUuid == acct && profile.orgUuid == orgB)
        #expect(!profile.isDefault)
    }

    @Test func fallsBackToTheFolderWithTheNewestCard() throws {
        let home = try TempHome()
        let data = home.url.appending(path: "Profiles/p/Data", directoryHint: .isDirectory)
        try home.writeJSON("Profiles/p/Data/config.json", ["lastKnownAccountUuid": acct])
        let old = try home.write("Profiles/p/Data/claude-code-sessions/\(acct)/\(orgA)/local_old.json", "{}")
        try home.write("Profiles/p/Data/claude-code-sessions/\(acct2)/\(orgB)/local_new.json", "{}")
        try home.write("Profiles/p/Data/claude-code-sessions/\(acct2)/\(orgB)/deleted_x", "1")
        try FileManager.default.createDirectory(at: data.appending(path: "claude-code-sessions/\(acct)/\(orgB)"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: old.path)

        let profile = ClaudeProfiles(paths: home.paths, processes: { [] }).resolve(ClaudeAccountInfo(dataDir: data.path, accountUuid: acct))

        #expect(profile.accountUuid == acct2)
        #expect(profile.orgUuid == orgB)
    }

    @Test func fallsBackToTheStoredAccountWhenNoCardSaysMore() throws {
        let home = try TempHome()
        let data = home.url.appending(path: "Profiles/p/Data", directoryHint: .isDirectory)
        try home.writeJSON("Profiles/p/Data/config.json", ["lastKnownAccountUuid": acct2])
        let profiles = ClaudeProfiles(paths: home.paths, processes: { [] })

        let bare = profiles.resolve(ClaudeAccountInfo(dataDir: data.path, accountUuid: acct))
        #expect(bare.accountUuid == acct && bare.orgUuid == nil && bare.cardsDir == nil)

        // An empty org folder of that account is the one the app will load.
        try FileManager.default.createDirectory(at: data.appending(path: "claude-code-sessions/\(acct)/\(orgA)"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data.appending(path: "claude-code-sessions/\(acct2)/\(orgB)"), withIntermediateDirectories: true)
        let fresh = profiles.resolve(ClaudeAccountInfo(dataDir: data.path, accountUuid: acct))
        #expect(fresh.accountUuid == acct && fresh.orgUuid == orgA)
    }

    @Test func noAccountMeansNoCardsFolder() throws {
        let home = try TempHome()
        let profile = ClaudeProfiles(paths: home.paths, processes: { [] }).resolve(ClaudeAccountInfo(dataDir: home.url.appending(path: "nothing").path))
        #expect(profile.accountUuid == nil)
        #expect(profile.cardsDir == nil)
        // An unsafe stored account id is ignored, never used as a path.
        let unsafe = ClaudeProfiles(paths: home.paths, processes: { [] }).resolve(ClaudeAccountInfo(accountUuid: "../../etc"))
        #expect(unsafe.accountUuid == nil)
    }

    @Test func mapsRunningProcessesToDataFolders() throws {
        let home = try TempHome()
        let custom = home.url.appending(path: "Profiles/p/Data", directoryHint: .isDirectory)
        let profiles = ClaudeProfiles(paths: home.paths) {
            [
                ClaudeProcess(pid: 10, arguments: ["/Applications/Claude.app/Contents/MacOS/Claude"], launchDate: nil),
                ClaudeProcess(pid: 11, arguments: ["/Applications/Claude.app/Contents/MacOS/Claude", "--user-data-dir=\(custom.path)"], launchDate: nil),
                ClaudeProcess(pid: 12, arguments: ["Claude Helper", "--type=renderer", "--user-data-dir=\(custom.path)"], launchDate: nil),
                ClaudeProcess(pid: 13, arguments: ["/Applications/Claude.app/Contents/MacOS/Claude", "--user-data-dir=~/Profiles/q"], launchDate: nil),
            ]
        }

        let running = profiles.running()

        #expect(running.map(\.pid) == [10, 11, 13])
        #expect(running[0].dataDir.path == home.paths.claudeDefaultDataDir.path)
        #expect(running[1].dataDir.path == custom.path)
        #expect(running[2].dataDir.path == home.url.appending(path: "Profiles/q").path)
        #expect(profiles.runningByPath()?[custom.path]?.pid == 11)
    }

    @Test func unreadableProcessMakesRunningStateUnknown() throws {
        let home = try TempHome()
        let profiles = ClaudeProfiles(paths: home.paths) { [ClaudeProcess(pid: 10, arguments: nil, launchDate: nil)] }
        #expect(profiles.running().isEmpty)
        #expect(profiles.runningByPath() == nil)
    }

    @Test func launchesDefaultWithoutArgumentsAndOthersWithTheirFolder() throws {
        let home = try TempHome()
        let profiles = ClaudeProfiles(paths: home.paths, processes: { [] })
        let custom = home.url.appending(path: "Profiles/p/Data", directoryHint: .isDirectory)
        #expect(profiles.launchArguments(for: profiles.resolve(ClaudeAccountInfo())) == [])
        #expect(profiles.launchArguments(for: profiles.resolve(ClaudeAccountInfo(dataDir: home.paths.claudeDefaultDataDir.path))) == [])
        #expect(profiles.launchArguments(for: profiles.resolve(ClaudeAccountInfo(dataDir: custom.path))) == ["--user-data-dir=\(custom.path)"])
    }

    @Test func discoversDefaultAndContextSwitcherProfilesWithLauncherLabels() throws {
        let home = try TempHome()
        try FileManager.default.createDirectory(at: home.paths.claudeDefaultDataDir, withIntermediateDirectories: true)
        let root = ".context-switcher-claude/profiles"
        try FileManager.default.createDirectory(at: home.url.appending(path: "\(root)/work/desktop-data"), withIntermediateDirectories: true)
        try home.write("\(root)/work/profile.toml", """
            [profile]
            name = "work"
            cli_config_dir = "/wrong/section"

            [isolation]
            desktop_user_data_dir = "/x/desktop-data"
            cli_config_dir = "/Users/x/.context-switcher-claude/profiles/work/cli-data"  # comment

            [sharing]
            cli_history = "isolate"
            """)
        try FileManager.default.createDirectory(at: home.url.appending(path: "\(root)/bare/desktop-data"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.url.appending(path: "\(root)/no-data"), withIntermediateDirectories: true)
        for (app, profile, email) in [("work", "work", "work@example.com"), ("hi", "default", "me@example.com")] {
            let plist: [String: Any] = ["CFBundleDisplayName": "Claude — \(email)", "ClaudeSyncProfile": profile]
            try home.write("Applications/Claude Profiles/Claude — \(app).app/Contents/Info.plist",
                           PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        }

        let found = ClaudeProfiles(paths: home.paths, processes: { [] }).discover()

        #expect(found == [
            DiscoveredClaudeProfile(dataDir: nil, label: "me@example.com", legacyConfigDir: nil),
            DiscoveredClaudeProfile(dataDir: home.url.appending(path: "\(root)/bare/desktop-data").path, label: "bare", legacyConfigDir: nil),
            DiscoveredClaudeProfile(
                dataDir: home.url.appending(path: "\(root)/work/desktop-data").path, label: "work@example.com",
                legacyConfigDir: "/Users/x/.context-switcher-claude/profiles/work/cli-data"
            ),
        ])
    }

    @Test func makesProfileDirectoryUnderAppSupport() throws {
        let home = try TempHome()
        let id = UUID()
        let dir = try ClaudeProfiles(paths: home.paths, processes: { [] }).makeProfileDirectory(id: id)
        #expect(dir.path == home.paths.appSupport.path + "/Claude/\(id.uuidString)/Data")
        #expect(ClaudeProfiles.directoryExists(dir))
        #expect(!dir.path.contains("/.claude/"))
    }
}
