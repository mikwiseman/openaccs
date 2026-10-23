import Foundation
import Testing
@testable import SetupKit

/// Settings files shaped like the ones on Mik's Mac (as the app writes them: insertion order, no final newline).
enum ClaudeConfigs {
    static let secret = "ctx7sk-not-a-real-key-123"

    static let hi = """
    {
      "preferences": {
        "bypassPermissionsModeEnabled": true,
        "bypassPermissionsOptInByAccount": {
          "acct-hi": true
        },
        "chicagoBackgroundIntroSeen": true,
        "dispatchCodeTasksPermissionMode": "auto",
        "menuBarEnabled": false,
        "ccdScheduledTasksEnabled": false,
        "sidebarMode": "epitaxy",
        "launchPreviewAllowedOrigins": [
          "http://localhost:3000"
        ],
        "epitaxyPrefs": {
          "fastMode": true,
          "cc-landing-draft-permission-mode": "default",
          "cc-landing-draft-permission-mode.acct-hi": "auto",
          "epitaxy-folder-permission-mode-v2.acct-hi": {
            "/Users/mik/code": "bypassPermissions",
            "/Users/mik/site": "bypassPermissions"
          },
          "epitaxy-auto-mode-consented.acct-hi": true,
          "epitaxy-auto-mode-denial-count.acct-hi": 3,
          "starred-local-code-sessions": [
            "local_1"
          ],
          "dframe-local-slice": {
            "pinnedOrder": [
              "code:local_1"
            ]
          }
        }
      },
      "mcpServers": {
        "context7": {
          "command": "npx",
          "args": [
            "-y",
            "@upstash/context7-mcp"
          ],
          "env": {
            "CONTEXT7_API_KEY": "\(secret)"
          }
        }
      },
      "coworkUserFilesPath": "/Users/mik/Claude",
      "deploymentMode": "1p"
    }
    """

    static let ai41 = """
    {
      "coworkUserFilesPath": "/Users/mik/Claude",
      "preferences": {
        "ccdScheduledTasksEnabled": true,
        "coworkWebSearchEnabled": true,
        "sidebarMode": "epitaxy",
        "bypassPermissionsGateByAccount": {
          "acct-41": true
        },
        "epitaxyPrefs": {
          "epitaxy-folder-permission-mode-v2.acct-41": {
            "/tmp/scratch": "default"
          },
          "epitaxy-perm-mode-acks-v2.acct-41": {
            "/tmp/scratch": true
          },
          "starred-local-code-sessions": [
            "local_2"
          ],
          "dframe-local-slice": {
            "pinnedOrder": [
              "code:local_2"
            ]
          }
        }
      }
    }
    """

    static let ai42 = """
    {
      "preferences": {
        "menuBarEnabled": false,
        "epitaxyPrefs": {
          "epitaxy-folder-permission-mode-v2.acct-42": {},
          "epitaxy-folder-permission-mode.acct-42": {
            "/Users/mik/old": "bypassPermissions"
          }
        }
      }
    }
    """
}

extension SetupHome {
    /// A Claude profile folder `Profiles/<name>` with this settings file (none when nil), dated `modified`.
    func claudeProfile(_ name: String, account: String?, config: String?, modified: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> ClaudeProfileRef {
        try claudeProfile(at: "Profiles/\(name)", account: account, config: config, modified: modified)
    }

    func claudeProfile(at relative: String, account: String?, config: String?, modified: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> ClaudeProfileRef {
        let ref = ClaudeProfileRef(dataDir: url.appending(path: relative, directoryHint: .isDirectory), accountUuid: account)
        try FileManager.default.createDirectory(at: ref.dataDir, withIntermediateDirectories: true)
        if let config {
            try write("\(relative)/claude_desktop_config.json", config)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: configPath(ref))
        }
        return ref
    }

    func configPath(_ ref: ClaudeProfileRef) -> String { ref.dataDir.appending(path: "claude_desktop_config.json").path }

    func config(_ ref: ClaudeProfileRef) -> [String: Any]? {
        (try? Data(contentsOf: URL(filePath: configPath(ref)))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// Changes one value the way the app would, then dates the file.
    func set(_ ref: ClaudeProfileRef, _ place: [String], to value: Any, modified: Date) throws {
        let object = ClaudeAppSetup.setting(place[...], to: value, in: try #require(config(ref)))
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: URL(filePath: configPath(ref)))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: configPath(ref))
    }

    func claudeContext(_ profiles: [ClaudeProfileRef], running: Set<SetupApp> = []) -> SetupContext {
        SetupContext(home: url, claudeProfiles: profiles, isRunning: { running.contains($0) }, run: { _ in nil })
    }

    /// Every file, folder and link under the home, with what it holds.
    func snapshot() -> [String: FileState] {
        var all: [String: FileState] = [:]
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for item in items { all[item.path] = FileState.of(item) }
        return all
    }

    func recordFiles() -> [String] {
        let dir = url.appending(path: "Library/Application Support/OpenAccs/setup-claude-app")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }
    }
}

/// The object without the shared settings (folder modes under `account`), to check nothing else changed.
func unshared(_ object: [String: Any], account: String?) -> NSDictionary {
    func removing(_ place: ArraySlice<String>, from object: [String: Any]) -> [String: Any] {
        guard let key = place.first else { return object }
        var object = object
        if place.count == 1 { object[key] = nil } else if let inner = object[key] as? [String: Any] { object[key] = removing(place.dropFirst(), from: inner) }
        return object
    }
    var object = object
    let ref = ClaudeProfileRef(dataDir: URL(filePath: "/"), accountUuid: account)
    for setting in ClaudeAppSetup.all {
        if let place = ClaudeAppSetup.keyPath(setting, ref) { object = removing(place[...], from: object) }
    }
    return object as NSDictionary
}

func value(_ object: [String: Any]?, _ place: [String]) -> NSObject? {
    object.flatMap { ClaudeAppSetup.value(at: place, in: $0) as? NSObject }
}

@Suite struct ClaudeAppTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theFirstSyncTakesTheProfileUsedLastAndAddsSettingsOnlyOthersHave() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41, modified: base + 600)

        let report = ClaudeAppSetup.scan(home.claudeContext([hi, ai41]))

        #expect(report.area == .claudeApp)
        #expect(report.summary == "2 profiles · 2 differ")
        #expect(report.changes.map(\.title) == ["hi gets 1 setting from ai41", "ai41 gets 8 settings from hi"])
        #expect(report.changes.map(\.waitsFor) == [.claude(hi.dataDir.path), .claude(ai41.dataDir.path)])
        #expect(report.changes[0].detail?.hasPrefix("Sets coworkWebSearchEnabled.") == true)
        let written = try #require(report.changes[1].operations.compactMap { operation -> [String: Any]? in
            guard case .write(let path, let contents, _, .file) = operation, path == home.configPath(ai41) else { return nil }
            return (try? JSONSerialization.jsonObject(with: contents)) as? [String: Any]
        }.first)
        // ai41's own values lose to hi's, even though ai41's file is newer: nothing was agreed before.
        #expect(value(written, ["preferences", "ccdScheduledTasksEnabled"]) == false as NSNumber)
        #expect(value(written, ["preferences", "epitaxyPrefs", "fastMode"]) == true as NSNumber)
        #expect(value(written, ["preferences", "coworkWebSearchEnabled"]) == true as NSNumber)
        #expect(report.items.map(\.name) == ["hi", "ai41"])
        #expect(report.items.map(\.claude) == [.differs, .differs])
        #expect(report.items.map(\.note) == ["1 setting differs", "8 settings differ"])
    }

    @Test func aNewProfileUsedLastDoesNotOverrideTheOneSomeoneSetUp() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41, modified: base + 600)

        // ai41 is the window used last, but hi has far more of these settings: hi's win on the first sync.
        let report = ClaudeAppSetup.scan(home.claudeContext([ai41, hi]))

        #expect(report.changes.map(\.title) == ["ai41 gets 8 settings from hi", "hi gets 1 setting from ai41"])
        #expect(report.changes.map(\.id) == ["claudeApp.ai41", "claudeApp.hi"])
    }

    @Test func onlyTheSharedSettingsChangeAndEveryOtherKeyKeepsItsValue() throws {
        #expect(ClaudeAppSetup.all.flatMap { $0 }.allSatisfy { key in
            ["Consent", "OptIn", "Gate", "Seen", "Nudge", "Ack", "Intro", "Onboarding", "Count"].allSatisfy { !key.contains($0) }
        })
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41)
        let before = try #require(home.config(ai41)), hiBefore = try #require(home.config(hi))

        let result = SetupApplier(context: home.claudeContext([hi, ai41])).apply(ClaudeAppSetup.scan(home.claudeContext([hi, ai41])).changes)

        #expect(result.applied.count == 2 && result.skipped.isEmpty)
        let after = try #require(home.config(ai41)), hiAfter = try #require(home.config(hi))
        #expect(unshared(after, account: "acct-41") == unshared(before, account: "acct-41"))
        #expect(unshared(hiAfter, account: "acct-hi") == unshared(hiBefore, account: "acct-hi"))
        for setting in ClaudeAppSetup.shared {
            #expect(value(after, setting) == value(hiAfter, setting), "\(setting)")
        }
        #expect(value(after, ["mcpServers"]) == value(hiBefore, ["mcpServers"]))
        // Pins belong to ClaudeKit's pin sync: each profile keeps its own.
        for pins in ["starred-local-code-sessions", "dframe-local-slice"].map({ ["preferences", "epitaxyPrefs", $0] }) {
            #expect(value(after, pins) == value(before, pins))
            #expect(value(hiAfter, pins) == value(hiBefore, pins))
            #expect(value(after, pins) != value(hiAfter, pins))
        }
        // Written sorted with a two-space indent.
        let text = try #require(home.read("Profiles/ai41/claude_desktop_config.json"))
        #expect(text.hasPrefix("{\n  \"coworkUserFilesPath\" : "))
        #expect(text == String(decoding: try #require(ClaudeAppSetup.serialize(after)), as: UTF8.self))
    }

    @Test func folderModesGoToEachProfilesOwnAccountAndSkipAnUnknownOne() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41)
        let ai42 = try home.claudeProfile("ai42", account: nil, config: ClaudeConfigs.ai42)
        let ai42Before = try #require(home.config(ai42))
        let context = home.claudeContext([hi, ai41, ai42])

        let report = ClaudeAppSetup.scan(context)
        _ = SetupApplier(context: context).apply(report.changes)

        #expect(report.changes.first { $0.waitsFor == .claude(ai42.dataDir.path) }?.detail?.contains("epitaxy-folder-permission-mode-v2") == false)
        let hiModes = value(home.config(hi), ["preferences", "epitaxyPrefs", "epitaxy-folder-permission-mode-v2.acct-hi"])
        #expect(hiModes != nil)
        #expect(value(home.config(ai41), ["preferences", "epitaxyPrefs", "epitaxy-folder-permission-mode-v2.acct-41"]) == hiModes)
        #expect(value(home.config(ai41), ["preferences", "epitaxyPrefs", "epitaxy-folder-permission-mode-v2.acct-hi"]) == nil)
        let ai42Prefs = ["preferences", "epitaxyPrefs"]
        #expect(value(home.config(ai42), ai42Prefs + ["epitaxy-folder-permission-mode-v2.acct-42"]) == value(ai42Before, ai42Prefs + ["epitaxy-folder-permission-mode-v2.acct-42"]))
        #expect(value(home.config(ai42), ai42Prefs + ["epitaxy-folder-permission-mode.acct-42"]) == value(ai42Before, ai42Prefs + ["epitaxy-folder-permission-mode.acct-42"]))
        #expect(value(home.config(ai42), ai42Prefs + ["epitaxy-folder-permission-mode-v2.acct-hi"]) == nil)
        #expect(value(home.config(ai42), ["preferences", "epitaxyPrefs", "fastMode"]) == true as NSNumber)
    }

    @Test func aChangeSinceTheLastSyncWinsAndTheNewestChangeWinsWhenTwoDisagree() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41)
        let ai42 = try home.claudeProfile("ai42", account: "acct-42", config: ClaudeConfigs.ai42)
        let context = home.claudeContext([hi, ai41, ai42])
        #expect(SetupApplier(context: context).apply(ClaudeAppSetup.scan(context).changes).skipped.isEmpty)
        #expect(ClaudeAppSetup.scan(context).changes.isEmpty)

        // hi is used last, but the changes were made in the other two.
        let now = Date()
        try home.set(ai41, ["preferences", "epitaxyPrefs", "fastMode"], to: false, modified: now + 100)
        try home.set(ai41, ["preferences", "dispatchCodeTasksPermissionMode"], to: "ask", modified: now + 100)
        try home.set(ai42, ["preferences", "dispatchCodeTasksPermissionMode"], to: "acceptEdits", modified: now + 200)
        let report = ClaudeAppSetup.scan(context)

        #expect(report.changes.map(\.title) == ["hi gets 2 settings from ai41 and ai42", "ai41 gets 1 setting from ai42", "ai42 gets 1 setting from ai41"])
        _ = SetupApplier(context: context).apply(report.changes)
        for profile in [hi, ai41, ai42] {
            #expect(value(home.config(profile), ["preferences", "epitaxyPrefs", "fastMode"]) == false as NSNumber)
            #expect(value(home.config(profile), ["preferences", "dispatchCodeTasksPermissionMode"]) == "acceptEdits" as NSString)
        }
        #expect(ClaudeAppSetup.scan(context).changes.isEmpty)

        // ai42 alone changes a setting, so only the others are written; its record rides along with their change,
        // and changing it back later still counts as a change.
        try home.set(ai42, ["preferences", "menuBarEnabled"], to: true, modified: now + 300)
        let only = ClaudeAppSetup.scan(context)
        #expect(only.changes.map(\.title) == ["hi gets 1 setting from ai42", "ai41 gets 1 setting from ai42"])
        _ = SetupApplier(context: context).apply(only.changes)
        try home.set(ai42, ["preferences", "menuBarEnabled"], to: false, modified: now + 400)
        #expect(ClaudeAppSetup.scan(context).changes.map(\.title) == ["hi gets 1 setting from ai42", "ai41 gets 1 setting from ai42"])
    }

    @Test func aRunningProfileWaitsAndItsOldValuesNeverUndoTheSync() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41)
        let running = home.claudeContext([hi, ai41], running: [.claude(ai41.dataDir.path)])

        let report = ClaudeAppSetup.scan(running)
        #expect(report.items.map(\.claude) == [.differs, .waiting])
        let result = SetupApplier(context: running).apply(report.changes)
        #expect(result.applied.map(\.title) == ["hi gets 1 setting from ai41"])
        #expect(result.skipped.map(\.reason) == ["waits for the Claude window using ai41 to close"])
        #expect(home.read("Profiles/ai41/claude_desktop_config.json") == ClaudeConfigs.ai41)
        #expect(ClaudeAppSetup.scan(running).summary == "2 profiles · 1 differs")

        // The app saves its file again on quit (newest now), with the values it had: still not a change.
        try FileManager.default.setAttributes([.modificationDate: Date() + 600], ofItemAtPath: home.configPath(ai41))
        let stopped = home.claudeContext([hi, ai41])
        #expect(ClaudeAppSetup.scan(stopped).changes.map(\.title) == ["ai41 gets 8 settings from hi"])
        _ = SetupApplier(context: stopped).apply(ClaudeAppSetup.scan(stopped).changes)
        #expect(ClaudeAppSetup.scan(stopped).summary == "Same in 2 profiles · 10 settings")
    }

    @Test func aSettingChangedInAProfileWhileItsWriteWaitsStillWins() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41)
        let running = home.claudeContext([hi, ai41], running: [.claude(ai41.dataDir.path)])
        _ = SetupApplier(context: running).apply(ClaudeAppSetup.scan(running).changes)

        // ai41 was never written, yet what the user changes there while it runs is a change, and the newest.
        try home.set(ai41, ["preferences", "sidebarMode"], to: "chat", modified: Date() + 600)
        let report = ClaudeAppSetup.scan(running)
        #expect(report.changes.map(\.title) == ["hi gets 1 setting from ai41", "ai41 gets 8 settings from hi"])

        let stopped = home.claudeContext([hi, ai41])
        #expect(SetupApplier(context: stopped).apply(ClaudeAppSetup.scan(stopped).changes).skipped.isEmpty)
        for profile in [hi, ai41] {
            #expect(value(home.config(profile), ["preferences", "sidebarMode"]) == "chat" as NSString)
        }
        #expect(ClaudeAppSetup.scan(stopped).changes.isEmpty)
    }

    @Test func aProfileClosedBetweenScanAndApplyRecordsWhatItWasWritten() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41)
        let stopped = home.claudeContext([hi, ai41])
        #expect(SetupApplier(context: stopped).apply(ClaudeAppSetup.scan(stopped).changes).skipped.isEmpty)
        try home.set(hi, ["preferences", "menuBarEnabled"], to: true, modified: Date() + 100)

        // Scanned while ai41 runs; the user quits it, as its row asks, and applies that plan.
        let plan = ClaudeAppSetup.scan(home.claudeContext([hi, ai41], running: [.claude(ai41.dataDir.path)]))
        #expect(plan.changes.map(\.title) == ["ai41 gets 1 setting from hi"])
        #expect(SetupApplier(context: stopped).apply(plan.changes).skipped.isEmpty)
        #expect(ClaudeAppSetup.scan(stopped).changes.isEmpty)

        // Turning it back off in ai41 is a change of its own, so it spreads instead of being undone.
        try home.set(ai41, ["preferences", "menuBarEnabled"], to: false, modified: Date() + 200)
        #expect(ClaudeAppSetup.scan(stopped).changes.map(\.title) == ["hi gets 1 setting from ai41"])
    }

    @Test func profilesWithTheSameNameGetChangesOfTheirOwn() throws {
        let home = try SetupHome()
        let main = try home.claudeProfile(at: "Library/Application Support/Claude", account: "acct-hi", config: ClaudeConfigs.hi)
        let one = try home.claudeProfile(at: "Library/Application Support/OpenAccs/Claude/A1/Data", account: "acct-41", config: ClaudeConfigs.ai41)
        let two = try home.claudeProfile(at: "Library/Application Support/OpenAccs/Claude/A2/Data", account: "acct-42", config: ClaudeConfigs.ai42)
        try home.write("Library/Application Support/OpenAccs/accounts.json", """
        [
          {"id": "6D2C1F7E-3E59-4C1B-9A57-0B8E5C2F1A01", "provider": "claude", "label": "Main", "color": 0, "createdAt": "2026-10-01T00:00:00Z", "claude": {}},
          {"id": "6D2C1F7E-3E59-4C1B-9A57-0B8E5C2F1A02", "provider": "claude", "label": "Claude", "color": 1, "createdAt": "2026-10-01T00:00:00Z",
           "claude": {"dataDir": "\(one.dataDir.path)"}},
          {"id": "6D2C1F7E-3E59-4C1B-9A57-0B8E5C2F1A03", "provider": "claude", "label": "claude", "color": 2, "createdAt": "2026-10-01T00:00:00Z",
           "claude": {"dataDir": "\(two.dataDir.path)"}}
        ]
        """)
        let context = home.claudeContext([main, one, two])

        let ids = ClaudeAppSetup.scan(context).changes.map(\.id)

        #expect(ids.count == 3 && Set(ids).count == 3)
        #expect(ids[0] == "claudeApp.main" && ids.dropFirst().allSatisfy { $0.hasPrefix("claudeApp.claude-") })
        #expect(ClaudeAppSetup.scan(context).changes.map(\.id) == ids)   // the same on every scan
        let result = SetupApplier(context: context).apply(ClaudeAppSetup.scan(context).changes.filter { $0.id == ids[2] })
        #expect(result.applied.count == 1)
        #expect(home.read("Library/Application Support/OpenAccs/Claude/A1/Data/claude_desktop_config.json") == ClaudeConfigs.ai41)
    }

    @Test func aProfileNewToTheSyncTakesTheAgreedValuesAndAddsWhatOnlyItHas() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41)
        let synced = home.claudeContext([hi, ai41])
        _ = SetupApplier(context: synced).apply(ClaudeAppSetup.scan(synced).changes)

        // Its file is the newest, but it changed nothing since a sync it was never part of.
        let ai42 = try home.claudeProfile("ai42", account: "acct-42", config: """
        {"preferences": {"menuBarEnabled": true, "dockBounceEnabled": false}}
        """, modified: Date() + 600)
        let context = home.claudeContext([hi, ai41, ai42])
        let report = ClaudeAppSetup.scan(context)

        #expect(report.summary == "3 profiles · 3 differ")
        #expect(report.changes.map(\.title) == ["hi gets 1 setting from ai42", "ai41 gets 1 setting from ai42", "ai42 gets 10 settings from hi"])
        _ = SetupApplier(context: context).apply(report.changes)
        for profile in [hi, ai41, ai42] {
            #expect(value(home.config(profile), ["preferences", "menuBarEnabled"]) == false as NSNumber)
            #expect(value(home.config(profile), ["preferences", "dockBounceEnabled"]) == false as NSNumber)
        }
        #expect(ClaudeAppSetup.scan(context).summary == "Same in 3 profiles · 11 settings")
    }

    @Test func mcpServersAreCopiedButTheirValuesNeverShowOrLeaveTheProfiles() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41)
        let context = home.claudeContext([hi, ai41])

        let report = ClaudeAppSetup.scan(context)
        _ = SetupApplier(context: context).apply(report.changes)

        let said = [report.summary] + report.changes.flatMap { [$0.title, $0.detail ?? ""] } + report.items.flatMap { [$0.name, $0.note ?? ""] }
            + report.attention.map(\.text)
        #expect(!said.joined().contains(ClaudeConfigs.secret))
        #expect(report.changes[1].detail?.contains("mcpServers") == true)
        #expect(home.read("Profiles/ai41/claude_desktop_config.json")?.contains(ClaudeConfigs.secret) == true)
        let records = home.recordFiles()
        #expect(records.count == 2)
        for record in records {
            #expect(home.read("Library/Application Support/OpenAccs/setup-claude-app/\(record)")?.contains(ClaudeConfigs.secret) == false)
        }
    }

    @Test func summaryAndItemsDescribeWhatWasRead() throws {
        let home = try SetupHome()
        #expect(ClaudeAppSetup.scan(home.claudeContext([])).summary == "No Claude app settings found")
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        #expect(ClaudeAppSetup.scan(home.claudeContext([hi])).summary == "1 profile · 9 settings")
        let fresh = try home.claudeProfile("fresh", account: nil, config: nil)
        let broken = try home.claudeProfile("broken", account: nil, config: "{ not json")

        let report = ClaudeAppSetup.scan(home.claudeContext([hi, fresh, broken]))

        #expect(report.summary == "1 profile · 9 settings")
        #expect(report.changes.isEmpty)
        #expect(report.items.map(\.claude) == [.same, .missing, .missing])
        #expect(report.items.map(\.note) == [nil, "No settings file yet", "Its settings file can't be read"])
        #expect(report.items.allSatisfy { $0.codex == .notShared })
        #expect(!FileManager.default.fileExists(atPath: home.configPath(fresh)))
    }

    @Test func profilesAreNamedAsInOpenAccs() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile(at: "Library/Application Support/Claude", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile(at: "Library/Application Support/OpenAccs/Claude/7F00D329/Data", account: "acct-41", config: ClaudeConfigs.ai41)
        try home.write("Library/Application Support/OpenAccs/accounts.json", """
        [
          {"id": "6D2C1F7E-3E59-4C1B-9A57-0B8E5C2F1A01", "provider": "claude", "label": "hi@waiwai.is", "color": 0, "createdAt": "2026-10-01T00:00:00Z", "claude": {}},
          {"id": "6D2C1F7E-3E59-4C1B-9A57-0B8E5C2F1A02", "provider": "claude", "label": "ai41", "color": 1, "createdAt": "2026-10-01T00:00:00Z",
           "claude": {"dataDir": "\(ai41.dataDir.path)"}}
        ]
        """)

        let report = ClaudeAppSetup.scan(home.claudeContext([hi, ai41]))

        #expect(report.items.map(\.name) == ["hi@waiwai.is", "ai41"])
        #expect(report.changes.last?.title == "ai41 gets 8 settings from hi@waiwai.is")
        let running = home.claudeContext([hi, ai41], running: [.claude(ai41.dataDir.path)])
        #expect(SetupApplier(context: running).apply(report.changes).skipped.map(\.reason) == ["waits for the Claude window using ai41 to close"])
    }

    @Test func seedGivesANewProfileTheSharedSettingsThatBelongToNoAccount() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let new = home.url.appending(path: "Profiles/new", directoryHint: .isDirectory)

        try ClaudeAppSetup.seed(new, from: hi.dataDir)

        let seeded = try #require(home.config(ClaudeProfileRef(dataDir: new)))
        #expect(Set(seeded.keys) == ["preferences", "mcpServers"])
        let preferences = try #require(seeded["preferences"] as? [String: Any])
        #expect(Set(preferences.keys) == ["bypassPermissionsModeEnabled", "dispatchCodeTasksPermissionMode", "menuBarEnabled",
                                          "ccdScheduledTasksEnabled", "sidebarMode", "epitaxyPrefs"])
        #expect(Set((preferences["epitaxyPrefs"] as? [String: Any] ?? [:]).keys) == ["fastMode", "cc-landing-draft-permission-mode", "starred-local-code-sessions"])
        #expect(value(seeded, ["preferences", "epitaxyPrefs", "starred-local-code-sessions"]) == value(home.config(hi), ["preferences", "epitaxyPrefs", "starred-local-code-sessions"]))
        #expect(value(seeded, ["mcpServers"]) == value(home.config(hi), ["mcpServers"]))

        // Never over a file that is there, and nothing from a profile without one.
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41)
        try ClaudeAppSetup.seed(ai41.dataDir, from: hi.dataDir)
        #expect(home.read("Profiles/ai41/claude_desktop_config.json") == ClaudeConfigs.ai41)
        let empty = home.url.appending(path: "Profiles/empty", directoryHint: .isDirectory)
        try ClaudeAppSetup.seed(empty, from: home.url.appending(path: "Profiles/none"))
        #expect(!FileManager.default.fileExists(atPath: empty.appending(path: "claude_desktop_config.json").path))
    }

    @Test func scanningOnlyReads() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41)
        let ai42 = try home.claudeProfile("ai42", account: nil, config: ClaudeConfigs.ai42)
        let before = home.snapshot()

        let report = ClaudeAppSetup.scan(home.claudeContext([hi, ai41, ai42]))

        #expect(!report.changes.isEmpty)
        #expect(home.snapshot() == before)
    }

    @Test func applyThenScanFindsNothingLeftAndUndoPutsEveryByteBack() throws {
        let home = try SetupHome()
        let hi = try home.claudeProfile("hi", account: "acct-hi", config: ClaudeConfigs.hi)
        let ai41 = try home.claudeProfile("ai41", account: "acct-41", config: ClaudeConfigs.ai41)
        let ai42 = try home.claudeProfile("ai42", account: nil, config: ClaudeConfigs.ai42)
        let context = home.claudeContext([hi, ai41, ai42])
        let applier = SetupApplier(context: context)

        let report = ClaudeAppSetup.scan(context)
        #expect(report.summary == "3 profiles · 3 differ")
        let result = applier.apply(report.changes)

        #expect(result.applied.count == 3 && result.skipped.isEmpty)
        for profile in [ai41, ai42] {
            #expect(value(home.config(profile), ["preferences", "bypassPermissionsModeEnabled"]) == true as NSNumber)
            #expect(value(home.config(profile), ["preferences", "coworkWebSearchEnabled"]) == true as NSNumber)
        }
        #expect(value(home.config(hi), ["preferences", "coworkWebSearchEnabled"]) == true as NSNumber)
        #expect(home.recordFiles().count == 3)

        let again = ClaudeAppSetup.scan(context)
        #expect(again.changes.isEmpty)
        #expect(again.summary == "Same in 3 profiles · 10 settings")
        #expect(again.items.map(\.claude) == [.same, .same, .same])

        for entry in result.applied.reversed() { try applier.undo(entry.id) }
        #expect(home.read("Profiles/hi/claude_desktop_config.json") == ClaudeConfigs.hi)
        #expect(home.read("Profiles/ai41/claude_desktop_config.json") == ClaudeConfigs.ai41)
        #expect(home.read("Profiles/ai42/claude_desktop_config.json") == ClaudeConfigs.ai42)
        #expect(home.recordFiles().isEmpty)
        #expect(ClaudeAppSetup.scan(context).changes.map(\.title) == report.changes.map(\.title))
    }
}
