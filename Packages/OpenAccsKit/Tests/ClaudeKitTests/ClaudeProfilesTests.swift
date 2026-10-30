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

    @Test func anOlderLogNeverOverrulesTheUnreadPartOfANewerOne() throws {
        let home = try TempHome()
        let data = home.url.appending(path: "Profiles/p/Data", directoryHint: .isDirectory)
        // main.log named this window's folder before the part OpenAccs reads; main1.log is older still.
        try home.write("Library/Logs/Claude/main.log", "Loaded 1 persisted sessions from \(data.path)/claude-code-sessions/\(acct)/\(orgA)\n"
                       + String(repeating: "x", count: 4 << 20) + "\n")
        try home.write("Library/Logs/Claude/main1.log", "Loaded 1 persisted sessions from \(data.path)/claude-code-sessions/\(acct2)/\(orgB)\n")
        try home.write("Profiles/p/Data/claude-code-sessions/\(acct)/\(orgA)/local_a.json", "{}")
        let profiles = ClaudeProfiles(paths: home.paths, processes: { [] })
        let info = ClaudeAccountInfo(dataDir: data.path, accountUuid: acct)

        // What main.log's unread start said is newer than anything in main1.log: fall back to the stored account.
        let profile = profiles.resolve(info)
        #expect(profile.accountUuid == acct && profile.orgUuid == orgA && !profile.isConfirmed)

        // A newer log read whole that doesn't name the folder lets an older one speak.
        try home.write("Library/Logs/Claude/main.log", "Loaded 1 persisted sessions from /elsewhere/claude-code-sessions/\(acct)/\(orgA)\n")
        let older = profiles.resolve(info)
        #expect(older.accountUuid == acct2 && older.orgUuid == orgB && older.isConfirmed)
    }

    @Test func anAccountInTwoOrgsGivesNoLimitsKeyWithoutTheLog() throws {
        let home = try TempHome()
        let data = home.url.appending(path: "Profiles/p/Data", directoryHint: .isDirectory)
        try home.write("Profiles/p/Data/claude-code-sessions/\(acct)/\(orgA)/local_a.json", "{}")
        let profiles = ClaudeProfiles(paths: home.paths, processes: { [] })
        let info = ClaudeAccountInfo(dataDir: data.path, accountUuid: acct)
        #expect(profiles.resolve(info).limitsAccount(addedAs: acct) == ClaudeAccountKey(account: acct, org: orgA))
        // Card sync fills every folder of a window, so with two orgs the newest card can't tell which one it uses.
        try home.write("Profiles/p/Data/claude-code-sessions/\(acct)/\(orgB)/local_a.json", "{}")
        #expect(profiles.resolve(info).limitsAccount(addedAs: acct) == nil)
        // Claude's log names it again: no guess.
        try home.write("Library/Logs/Claude/main.log", "Loaded 1 persisted sessions from \(data.path)/claude-code-sessions/\(acct)/\(orgB)\n")
        #expect(profiles.resolve(info).limitsAccount(addedAs: acct) == ClaudeAccountKey(account: acct, org: orgB))
    }

    @Test func limitsFollowWhatClaudeNamesOrTheAccountTheWindowWasAddedWith() throws {
        let data = URL(filePath: "/tmp/p/Data", directoryHint: .isDirectory)
        func window(_ account: String?, _ org: String?, confirmed: Bool) -> ClaudeProfile {
            ClaudeProfile(dataDir: data, isDefault: false, accountUuid: account, orgUuid: org, isConfirmed: confirmed)
        }
        let key = try #require(ClaudeAccountKey(account: acct, org: orgA))
        #expect(key.description == "\(acct)/\(orgA)")
        #expect(window(acct, orgA, confirmed: true).limitsAccount(addedAs: nil) == key)
        #expect(window(acct, orgA, confirmed: false).limitsAccount(addedAs: acct.uppercased()) == key)
        #expect(window(acct.uppercased(), orgA.uppercased(), confirmed: true).limitsAccount(addedAs: nil) == key)
        // A guess at another account's newest card never decides whose limits a window shows.
        #expect(window(acct2, orgB, confirmed: false).limitsAccount(addedAs: acct) == nil)
        #expect(window(acct, orgA, confirmed: false).limitsAccount(addedAs: nil) == nil)
        #expect(window(acct, nil, confirmed: false).limitsAccount(addedAs: acct) == nil)
        #expect(ClaudeAccountKey(account: "../x", org: orgA) == nil)
        #expect(ClaudeAccountKey(account: acct, org: nil) == nil)
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

        let profiles = ClaudeProfiles(paths: home.paths, processes: { [] })

        // OpenAccs keeps every account folder current, so the account the profile was added with comes first...
        let stored = profiles.resolve(ClaudeAccountInfo(dataDir: data.path, accountUuid: acct))
        #expect(stored.accountUuid == acct && stored.orgUuid == orgA)
        // ...and without one, the folder with the newest card.
        let unknown = profiles.resolve(ClaudeAccountInfo(dataDir: data.path))
        #expect(unknown.accountUuid == acct2)
        #expect(unknown.orgUuid == orgB)
        #expect(profiles.loggedAccount(ClaudeAccountInfo(dataDir: data.path)) == nil)
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

    /// A second Claude instance can be up with its window shown while the system never reports the launch
    /// finished; opening must return once the profile's process is there.
    @MainActor @Test func openReturnsWhenTheProcessAppearsEvenIfTheLaunchNeverReportsBack() async throws {
        let home = try TempHome()
        let custom = home.url.appending(path: "Profiles/p/Data", directoryHint: .isDirectory)
        let launched = Flag()
        let profiles = ClaudeProfiles(
            paths: home.paths,
            processes: { launched.isSet ? [claudeProcess(pid: 10, dataDir: nil), claudeProcess(pid: 77, dataDir: custom)] : [claudeProcess(pid: 10, dataDir: nil)] },
            launch: { _, arguments, activate, _ in
                #expect(arguments == ["--user-data-dir=\(custom.path)"])
                #expect(activate)
                launched.set()   // and never calls back, like the real launch here
            }
        )
        let pid = try await profiles.open(profiles.resolve(ClaudeAccountInfo(dataDir: custom.path)), timeout: .seconds(5))
        #expect(pid == 77)
    }

    @MainActor @Test func openReportsALaunchThatFailsAndGivesUpWhenNothingStarts() async throws {
        let home = try TempHome()
        let custom = home.url.appending(path: "Profiles/p/Data", directoryHint: .isDirectory)
        struct Broken: Error {}
        let failing = ClaudeProfiles(paths: home.paths, processes: { [] }, launch: { _, _, _, done in done(Broken()) })
        await #expect(throws: Broken.self) {
            try await failing.open(failing.resolve(ClaudeAccountInfo(dataDir: custom.path)), timeout: .seconds(5))
        }
        let silent = ClaudeProfiles(paths: home.paths, processes: { [] }, launch: { _, _, _, _ in })
        await #expect(throws: ClaudeLaunchError.didNotStart) {
            try await silent.open(silent.resolve(ClaudeAccountInfo(dataDir: custom.path)), timeout: .milliseconds(600))
        }
    }

    @Test func launchesDefaultWithoutArgumentsAndOthersWithTheirFolder() throws {
        let home = try TempHome()
        let profiles = ClaudeProfiles(paths: home.paths, processes: { [] })
        let custom = home.url.appending(path: "Profiles/p/Data", directoryHint: .isDirectory)
        #expect(profiles.launchArguments(for: profiles.resolve(ClaudeAccountInfo())) == [])
        #expect(profiles.launchArguments(for: profiles.resolve(ClaudeAccountInfo(dataDir: home.paths.claudeDefaultDataDir.path))) == [])
        #expect(profiles.launchArguments(for: profiles.resolve(ClaudeAccountInfo(dataDir: custom.path))) == ["--user-data-dir=\(custom.path)"])
    }

    @MainActor @Test func backgroundOpenLeavesAnExistingProcessUntouched() async throws {
        let home = try TempHome()
        let custom = home.url.appending(path: "Profiles/p/Data", directoryHint: .isDirectory)
        let profiles = ClaudeProfiles(paths: home.paths, processes: { [claudeProcess(pid: 77, dataDir: custom)] },
                                      launch: { _, _, _, _ in Issue.record("Launched a second process") })
        let profile = profiles.resolve(ClaudeAccountInfo(dataDir: custom.path))
        for _ in 0..<3 { #expect(try await profiles.open(profile, activate: false) == 77) }
    }

    @MainActor @Test func backgroundOpenLaunchesWithoutActivationAndRefusesUnknownProcesses() async throws {
        let home = try TempHome()
        let custom = home.url.appending(path: "Profiles/p/Data", directoryHint: .isDirectory)
        let launched = Flag()
        let profiles = ClaudeProfiles(paths: home.paths,
            processes: { launched.isSet ? [claudeProcess(pid: 77, dataDir: custom)] : [] },
            launch: { _, _, activate, _ in
                #expect(!activate)
                launched.set()
            })
        #expect(try await profiles.open(profiles.resolve(ClaudeAccountInfo(dataDir: custom.path)), activate: false) == 77)
        let unknown = ClaudeProfiles(paths: home.paths, processes: { [ClaudeProcess(pid: 1, arguments: nil, launchDate: nil)] },
                                    launch: { _, _, _, _ in Issue.record("Launched with an unidentified process") })
        await #expect(throws: ClaudeLaunchError.alreadyRunning) {
            try await unknown.open(unknown.resolve(ClaudeAccountInfo(dataDir: custom.path)), activate: false)
        }
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
