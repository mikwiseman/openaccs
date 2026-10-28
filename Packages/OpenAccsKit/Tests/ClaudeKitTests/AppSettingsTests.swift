import Foundation
import OpenAccsCore
import Testing
@testable import ClaudeKit

private let org = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let mainAccount = "11111111-1111-4111-8111-111111111111"
private let otherAccount = "22222222-2222-4222-8222-222222222222"
private let thirdAccount = "33333333-3333-4333-8333-333333333333"
private let base = Date(timeIntervalSince1970: 1_800_000_000)

/// The Code tab's built-in sidebar sections, as the app saves them.
private func builtInSections(groupBy: String, pinnedCollapsed: Bool = false) -> [[String: Any]] {
    let show = ["metadata": false, "emptyGroups": false, "sideChats": false]
    return [
        ["id": "pinned", "kind": "pinned", "v": 2, "name": "", "order": 0, "sortBy": "recency", "ascending": false, "show": show,
         "collapsed": pinnedCollapsed, "shown": true],
        ["id": "routines", "kind": "routines", "v": 2, "name": "", "order": 1, "sortBy": "recency", "ascending": false, "show": show,
         "collapsed": true, "shown": false],
        ["id": "sessions", "kind": "sessions", "v": 2, "name": "", "order": 2, "sortBy": "recency", "ascending": false, "show": show,
         "collapsed": false, "shown": true, "groupBy": groupBy],
    ]
}

/// What a window holds, saved in the app's own shapes by `TempHome.save`.
private struct Settings {
    /// The composer's own fast mode: the app sets it from the new-session defaults at launch.
    var fastMode = false
    var sidebarMode = "epitaxy"
    var menuBar: Bool?
    var groupBy = "date"
    var folders: [String: String] = [:]
    /// Sections someone made (kind "manual"), after the built-in ones.
    var custom: [[String: Any]] = []
    /// The app made the account's sidebar (it does when the Code tab opens).
    var hasSidebar = true
    var mcp: [String: Any]?
    /// New-session defaults; nil: no presets file yet.
    var newSession: [String: Any]? = ["effort": "high", "fastMode": false, "modelId": "claude-opus-5-5", "worktree": false]

    func config(account: String?) -> [String: Any] {
        let mine = account ?? "unknown"
        var prefs: [String: Any] = [
            "fastMode": fastMode,
            // Not shared: pins (the pin sync's business), acknowledgements, counts.
            "starred-local-code-sessions": ["local_\(mine)"],
            "dframe-local-slice": ["pinnedOrder": ["code:local_\(mine)"], "homeProjectsPinnedOrder": []],
            "epitaxy-perm-mode-acks-v2.\(mine)": ["/code": true],
        ]
        if let account {
            if !folders.isEmpty { prefs["epitaxy-folder-permission-mode-v2.\(account)"] = folders }
            if hasSidebar {
                prefs["dframe-code-sections"] = ["\(account)/\(org)": ["migratedFrom": 1, "prefsSeeded": true,
                                                                      "sections": builtInSections(groupBy: groupBy) + custom]]
            }
        }
        var preferences: [String: Any] = ["sidebarMode": sidebarMode, "ccNewTaskPrompt": "ask", "bypassPermissionsGateByAccount": [mine: true],
                                          "epitaxyPrefs": prefs]
        if let menuBar { preferences["menuBarEnabled"] = menuBar }
        var config: [String: Any] = ["coworkUserFilesPath": "/Users/x/Claude", "preferences": preferences]
        if let mcp { config["mcpServers"] = mcp }
        return config
    }

    /// The sidebar store the app keeps in localStorage (the config's sections are its copy).
    func sidebarStore(account: String) -> [String: Any] {
        ["state": ["sidebarWidth": 288, "pinnedOrder": ["code:local_\(account)"],
                   "codeSidebarByScope": ["\(account)/\(org)": ["sections": builtInSections(groupBy: groupBy) + custom]],
                   "customGroupsByScope": ["\(account)/\(org)": ["groups": [], "assignments": [:], "order": [:]]]],
         "version": 3]
    }

    /// The new-session presets the app keeps in localStorage (`ccd-session-presets.json` is its copy).
    func presetsStore(account: String) -> [String: Any] {
        ["state": ["presets": [["id": "p_\(account)", "name": "openaccs", "target": ["kind": "local", "cwd": "/code/openaccs"], "createdAt": 1, "lastUsedAt": 2]],
                   "builtIns": ["local": ["settings": newSession ?? [:]]], "seededFromDraft": true, "fileMirrored": true],
         "version": 4]
    }
}

extension TempHome {
    /// A Claude window signed in to `account` (nil: not known yet).
    fileprivate func window(_ name: String, account: String?, isDefault: Bool = false) -> ClaudeProfile {
        ClaudeProfile(dataDir: url.appending(path: "Windows/\(name)/Data", directoryHint: .isDirectory), isDefault: isDefault,
                      accountUuid: account, orgUuid: account == nil ? nil : org)
    }

    /// Saves a window's settings the way its app does: its stores in localStorage, which it reads at launch, and
    /// their copies in its desktop config and new-session defaults file (dated `modified`).
    @discardableResult
    fileprivate func save(_ window: ClaudeProfile, _ settings: Settings, modified: Date = base, localStorage: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: window.dataDir, withIntermediateDirectories: true)
        if localStorage {
            try makeLocalStorage(in: window.dataDir)
            if let account = window.accountUuid {
                func put(_ key: String, _ object: [String: Any]) throws {
                    let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                    #expect(ChromiumLocalStorage.set(text, for: key, origin: PinList.origin, in: window.dataDir))
                }
                if settings.hasSidebar { try put("dframe-store", settings.sidebarStore(account: account)) }
                if settings.newSession != nil { try put("persisted.ccd-session-presets.\(account)", settings.presetsStore(account: account)) }
            }
        }
        let file = configFile(window)
        try JSONSerialization.data(withJSONObject: settings.config(account: window.accountUuid), options: [.prettyPrinted]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        if let account = window.accountUuid, let defaults = settings.newSession {
            let presets: [String: Any] = ["byAccount": [account: [
                "presets": [["id": "p_\(account)", "name": "openaccs", "target": ["kind": "local", "cwd": "/code/openaccs"], "createdAt": 1, "lastUsedAt": 2]],
                "builtIns": ["local": ["settings": defaults]],
                "seededFromDraft": true,
            ]]]
            let presetsFile = window.dataDir.appending(path: "ccd-session-presets.json")
            try JSONSerialization.data(withJSONObject: presets, options: [.prettyPrinted]).write(to: presetsFile)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: presetsFile.path)
        }
        return file
    }

    /// Changes one value of a window's config the way its app would, and dates the file.
    fileprivate func change(_ window: ClaudeProfile, at modified: Date, _ edit: (inout [String: Any]) -> Void) throws {
        var prefs = self.prefs(window)
        edit(&prefs)
        var config = json(at: configFile(window))
        var preferences = config["preferences"] as? [String: Any] ?? [:]
        preferences["epitaxyPrefs"] = prefs
        config["preferences"] = preferences
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]).write(to: configFile(window))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: configFile(window).path)
    }

    fileprivate func configFile(_ window: ClaudeProfile) -> URL { window.dataDir.appending(path: "claude_desktop_config.json") }

    fileprivate func prefs(_ window: ClaudeProfile) -> [String: Any] {
        (json(at: configFile(window))["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any] ?? [:]
    }

    fileprivate func folders(_ window: ClaudeProfile) -> [String: String]? {
        prefs(window)["epitaxy-folder-permission-mode-v2.\(window.accountUuid ?? "")"] as? [String: String]
    }

    /// The window's sidebar sections in the order it keeps them.
    fileprivate func sections(_ window: ClaudeProfile) -> [[String: Any]]? {
        ((prefs(window)["dframe-code-sections"] as? [String: Any])?["\(window.accountUuid ?? "")/\(org)"] as? [String: Any])?["sections"] as? [[String: Any]]
    }

    fileprivate func groupBy(_ window: ClaudeProfile) -> String? {
        sections(window)?.first { $0["id"] as? String == "sessions" }?["groupBy"] as? String
    }

    fileprivate func presets(_ window: ClaudeProfile) -> [String: Any] {
        json(at: window.dataDir.appending(path: "ccd-session-presets.json"))
    }

    fileprivate func newSession(_ window: ClaudeProfile) -> NSDictionary? {
        let account = (presets(window)["byAccount"] as? [String: Any])?[window.accountUuid ?? ""] as? [String: Any]
        return ((account?["builtIns"] as? [String: Any])?["local"] as? [String: Any])?["settings"] as? NSDictionary
    }

    /// A store the app keeps in localStorage, as JSON.
    fileprivate func store(_ window: ClaudeProfile, _ key: String) -> [String: Any]? {
        ChromiumLocalStorage.get(key, origin: PinList.origin, in: window.dataDir).flatMap { JSON.object(Data($0.utf8)) }
    }

    /// The sessions grouping the app shows at launch: its sidebar store's.
    fileprivate func shownGroupBy(_ window: ClaudeProfile) -> String? {
        let scope = ((store(window, "dframe-store")?["state"] as? [String: Any])?["codeSidebarByScope"] as? [String: Any])?["\(window.accountUuid ?? "")/\(org)"]
        return ((scope as? [String: Any])?["sections"] as? [[String: Any]])?.first { $0["id"] as? String == "sessions" }?["groupBy"] as? String
    }

    /// The new-session defaults the app uses at launch: its presets store's.
    fileprivate func shownNewSession(_ window: ClaudeProfile) -> NSDictionary? {
        let state = store(window, "persisted.ccd-session-presets.\(window.accountUuid ?? "")")?["state"] as? [String: Any]
        return ((state?["builtIns"] as? [String: Any])?["local"] as? [String: Any])?["settings"] as? NSDictionary
    }

    /// The value the app finds in its localStorage at launch (`LSS-persisted.<key>`, wrapped the app's way).
    fileprivate func stored(_ window: ClaudeProfile, _ key: String) -> Any? {
        guard let raw = localStorageValue(in: window.dataDir, "LSS-persisted.\(key)"),
              let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return nil }
        #expect(object["tabId"] as? String == "")
        #expect(object["timestamp"] is NSNumber)
        return object["value"]
    }

    fileprivate var state: SyncState { (try? SyncState.load(paths.syncStateFile)) ?? SyncState() }
}

/// One sync over these windows, the `running` ones open.
@discardableResult
private func sync(_ home: TempHome, _ windows: [ClaudeProfile], running: [ClaudeProfile] = [], pins: Bool = false) throws -> (SyncPlan, SyncReport) {
    let processes = running.enumerated().map { i, window in claudeProcess(pid: pid_t(300 + i), dataDir: window.dataDir) }
    let sync = CardSync(claude: ClaudeProfiles(paths: home.paths, processes: { processes }))
    let plan = try sync.plan(profiles: windows, running: Set(running.map(\.dataDir)), pins: pins)
    return (plan, try sync.apply(plan))
}

@Suite struct AppSettingsTests {
    let stoli = ["/code/stoli": "bypassPermissions", "/code/waiwai": "bypassPermissions"]
    let xhigh: [String: Any] = ["effort": "xhigh", "fastMode": true, "modelId": "claude-opus-5-5", "worktree": false]

    @Test func theFirstSyncTakesTheDefaultWindowsSettingsAndANewWindowNeverWins() throws {
        let home = try TempHome()
        let main = home.window("main", account: mainAccount, isDefault: true)
        let fresh = home.window("fresh", account: otherAccount)
        try home.save(main, Settings(menuBar: false, folders: stoli, newSession: xhigh))
        // Newer, and listed first (the window used last): it still only has the app's defaults.
        let freshConfig = try home.save(fresh, Settings(menuBar: true, folders: ["/code/openaccs": "bypassPermissions"]), modified: base + 600)

        let (plan, report) = try sync(home, [fresh, main])

        #expect(plan.count(.settings, for: fresh.dataDir) == 1)
        #expect(report.updated == 2 && report.skipped == 0 && report.failures.isEmpty)
        // The new window starts its next sessions like the default window's: the app's own presets store has
        // its defaults, and so does their copy, under the window's own account.
        #expect(home.shownNewSession(fresh) == xhigh as NSDictionary)
        #expect(home.newSession(fresh) == xhigh as NSDictionary)
        let presetsStore = home.store(fresh, "persisted.ccd-session-presets.\(otherAccount)")
        #expect(((presetsStore?["state"] as? [String: Any])?["presets"] as? [[String: Any]])?.first?["name"] as? String == "openaccs")
        #expect((presetsStore?["state"] as? [String: Any])?["fileMirrored"] as? Bool == true)
        #expect(presetsStore?["version"] as? Int == 4)
        #expect(home.json(at: freshConfig)["preferences"].flatMap { ($0 as? [String: Any])?["menuBarEnabled"] as? Bool } == false)
        // Folder modes are merged, not replaced: every window gets every folder, in its copy and in localStorage.
        let all = stoli.merging(["/code/openaccs": "bypassPermissions"]) { a, _ in a }
        #expect(home.folders(main) == all)
        #expect(home.folders(fresh) == all)
        #expect(home.stored(fresh, "epitaxy-folder-permission-mode-v2.\(otherAccount)") as? [String: String] == all)
        #expect(home.stored(main, "epitaxy-folder-permission-mode-v2.\(mainAccount)") as? [String: String] == all)
        #expect(home.newSession(main) == xhigh as NSDictionary)
        // Nothing else changes: the composer's own fast mode, the sidebar (Claude syncs it per account), pins,
        // acknowledgements, other preferences, the rest of the presets file, other localStorage.
        #expect(home.prefs(fresh)["fastMode"] as? Bool == false)
        #expect(home.shownGroupBy(fresh) == "date")
        #expect(home.localStorageValue(in: fresh.dataDir, "theme") == "dark")
        let config = home.json(at: freshConfig)
        #expect(config["coworkUserFilesPath"] as? String == "/Users/x/Claude")
        let preferences = config["preferences"] as? [String: Any]
        #expect(preferences?["ccNewTaskPrompt"] as? String == "ask")
        #expect(preferences?["bypassPermissionsGateByAccount"] as? [String: Bool] == [otherAccount: true])
        #expect(home.prefs(fresh)["starred-local-code-sessions"] as? [String] == ["local_\(otherAccount)"])
        #expect(home.prefs(fresh)["epitaxy-perm-mode-acks-v2.\(otherAccount)"] as? [String: Bool] == ["/code": true])
        #expect(home.prefs(fresh)["epitaxy-folder-permission-mode-v2.\(mainAccount)"] == nil)
        let presets = (home.presets(fresh)["byAccount"] as? [String: Any])?[otherAccount] as? [String: Any]
        #expect(presets?["seededFromDraft"] as? Bool == true)
        #expect((presets?["presets"] as? [[String: Any]])?.first?["name"] as? String == "openaccs")
        #expect(try FileManager.default.attributesOfItem(atPath: freshConfig.path)[.posixPermissions] as? Int == 0o600)

        // Everything is the same now: the next sync writes nothing.
        #expect(try sync(home, [fresh, main]).0.operations.isEmpty)
    }

    @Test func aChangeInAnyWindowFollowsEverywhereAndTheNewestChangeWins() throws {
        let home = try TempHome()
        let main = home.window("main", account: mainAccount, isDefault: true)
        let b = home.window("b", account: otherAccount), c = home.window("c", account: thirdAccount)
        try home.save(main, Settings(menuBar: true))
        try home.save(b, Settings())
        try home.save(c, Settings())
        try sync(home, [main, b, c])

        // The default window is used last, but the changes were made in the other two.
        try home.save(b, Settings(menuBar: false, newSession: xhigh), modified: base + 100)
        try home.save(c, Settings(menuBar: true, newSession: xhigh.merging(["effort": "max"]) { _, new in new }), modified: base + 200)
        try sync(home, [main, b, c])

        let newest = xhigh.merging(["effort": "max"]) { _, new in new } as NSDictionary
        for window in [main, b, c] {
            #expect(home.newSession(window) == newest)
            #expect(home.shownNewSession(window) == newest)
            #expect(home.json(at: home.configFile(window))["preferences"].flatMap { ($0 as? [String: Any])?["menuBarEnabled"] as? Bool } == false)
        }
        #expect(try sync(home, [main, b, c]).0.operations.isEmpty)
    }

    @Test func anOpenWindowWaitsAndItsOldValuesNeverUndoWhatWasAgreed() throws {
        let home = try TempHome()
        let main = home.window("main", account: mainAccount, isDefault: true)
        let open = home.window("open", account: otherAccount)
        try home.save(main, Settings(menuBar: false, newSession: xhigh))
        let config = try home.save(open, Settings(menuBar: true))
        let bytes = try Data(contentsOf: config)

        let (plan, _) = try sync(home, [main, open], running: [open])

        // Claude keeps its settings in memory while it runs: nothing is written, and its row asks for a restart.
        #expect(try Data(contentsOf: config) == bytes)
        #expect(home.shownNewSession(open)?["effort"] as? String == "high")
        #expect(plan.waiting(in: open.cardsDir!) == 2)
        // It saves its file again with the values it has (newest now): not a change of its own.
        try FileManager.default.setAttributes([.modificationDate: base + 900], ofItemAtPath: config.path)
        try sync(home, [main, open], running: [open])
        #expect(home.newSession(main) == xhigh as NSDictionary)

        // What the user changes there while it runs is a change, and it spreads.
        try home.change(open, at: base + 1000) { prefs in prefs["epitaxy-folder-permission-mode-v2.\(otherAccount)"] = ["/code/new": "plan"] }
        let (waiting, _) = try sync(home, [main, open], running: [open])
        #expect(home.folders(main) == ["/code/new": "plan"])
        #expect(waiting.waiting(in: open.cardsDir!) == 2)

        // Closed: it catches up.
        try sync(home, [main, open])
        #expect(home.newSession(open) == xhigh as NSDictionary && home.shownNewSession(open) == xhigh as NSDictionary)
        #expect(home.json(at: config)["preferences"].flatMap { ($0 as? [String: Any])?["menuBarEnabled"] as? Bool } == false)
        #expect(try sync(home, [main, open]).0.operations.isEmpty)
    }

    @Test func aFolderModeRemovedInOneWindowGoesEverywhereAndANewWindowAddsItsOwn() throws {
        let home = try TempHome()
        let main = home.window("main", account: mainAccount, isDefault: true)
        let b = home.window("b", account: otherAccount)
        try home.save(main, Settings(folders: stoli))
        try home.save(b, Settings(folders: ["/code/openaccs": "bypassPermissions"]))
        try sync(home, [main, b])

        try home.change(main, at: base + 100) { prefs in
            prefs["epitaxy-folder-permission-mode-v2.\(mainAccount)"] = ["/code/stoli": "bypassPermissions", "/code/openaccs": "bypassPermissions"]
        }
        try sync(home, [main, b])
        let left = ["/code/stoli": "bypassPermissions", "/code/openaccs": "bypassPermissions"]
        #expect(home.folders(main) == left)
        #expect(home.folders(b) == left)

        // A window added later keeps the agreed settings and adds the folders only it has.
        let c = home.window("c", account: thirdAccount)
        try home.save(c, Settings(folders: ["/code/new": "acceptEdits"], newSession: xhigh), modified: base + 900)
        try sync(home, [main, b, c])
        for window in [main, b, c] {
            #expect(home.folders(window) == left.merging(["/code/new": "acceptEdits"]) { a, _ in a })
            #expect(home.newSession(window)?["effort"] as? String == "high")
        }
    }

    @Test func theSidebarStaysWithClaudesOwnSyncAndWhatAWindowCantHoldIsLeftAlone() throws {
        let home = try TempHome()
        let main = home.window("main", account: mainAccount, isDefault: true)
        let b = home.window("b", account: otherAccount)
        let noPresets = home.window("noPresets", account: thirdAccount)
        let unknown = home.window("unknown", account: nil)
        try home.save(main, Settings(menuBar: false, groupBy: "folder", folders: stoli, newSession: xhigh))
        try home.save(b, Settings(menuBar: false))
        try home.save(noPresets, Settings(newSession: nil))
        try home.save(unknown, Settings())

        try sync(home, [main, b, noPresets, unknown])

        // Each window keeps its own sidebar: Claude syncs it per account and puts its own back at every launch.
        #expect(home.groupBy(b) == "date" && home.shownGroupBy(b) == "date")
        #expect(home.groupBy(main) == "folder")
        #expect(home.newSession(b) == xhigh as NSDictionary)
        // Presets the app hasn't made yet stay unmade; the rest still comes.
        #expect(!FS.exists(noPresets.dataDir.appending(path: "ccd-session-presets.json")))
        #expect(home.store(noPresets, "persisted.ccd-session-presets.\(thirdAccount)") == nil)
        #expect(home.json(at: home.configFile(noPresets))["preferences"].flatMap { ($0 as? [String: Any])?["menuBarEnabled"] as? Bool } == false)
        #expect(home.folders(noPresets) == stoli)
        // A window whose account isn't known gets only what belongs to no account.
        #expect(home.json(at: home.configFile(unknown))["preferences"].flatMap { ($0 as? [String: Any])?["menuBarEnabled"] as? Bool } == false)
        #expect(home.prefs(unknown).keys.filter { $0.hasPrefix("epitaxy-folder-permission-mode") }.isEmpty)
    }

    @Test func aWindowWhoseLocalStorageCantBeWrittenStaysAsItIsAndOneThatNeverRanGetsItsCopies() throws {
        let home = try TempHome()
        let main = home.window("main", account: mainAccount, isDefault: true)
        let broken = home.window("broken", account: otherAccount)
        let never = home.window("never", account: thirdAccount)
        try home.save(main, Settings(menuBar: false, folders: stoli, newSession: xhigh))
        let brokenConfig = try home.save(broken, Settings())
        try FileManager.default.removeItem(at: home.localStorageDir(broken.dataDir).appending(path: "CURRENT"))   // not in the shape expected
        let bytes = try Data(contentsOf: brokenConfig)
        try home.save(never, Settings(), localStorage: false)

        let (plan, report) = try sync(home, [main, broken, never])

        #expect(plan.count(.settings, for: broken.dataDir) == 1)
        #expect(report.skipped == 1)
        // The app would put its old values back from localStorage: the config is not touched either.
        #expect(try Data(contentsOf: brokenConfig) == bytes)
        // A window that never ran has no localStorage yet: the app reads the copies at first launch.
        #expect(home.newSession(never) == xhigh as NSDictionary)
        #expect(home.folders(never) == stoli)
        #expect(!FS.exists(home.localStorageDir(never.dataDir)))
    }

    @Test func mcpServersAreCopiedButKeysNeverReachTheSyncStateAndBackupsHoldOnlyWhatChanged() throws {
        let home = try TempHome()
        let secret = "ctx7sk-not-a-real-key-123"
        let main = home.window("main", account: mainAccount, isDefault: true)
        let b = home.window("b", account: otherAccount)
        let server: [String: Any] = ["command": "npx", "args": ["-y", "@upstash/context7-mcp"], "env": ["CONTEXT7_API_KEY": secret]]
        try home.save(main, Settings(menuBar: false, mcp: ["context7": server]))
        let config = try home.save(b, Settings(menuBar: true, mcp: ["linear": ["command": "linear-mcp"]]))

        try sync(home, [main, b])

        // Copied between windows on this Mac, merged server by server.
        for window in [main, b] {
            let servers = home.json(at: home.configFile(window))["mcpServers"] as? [String: Any] ?? [:]
            #expect(Set(servers.keys) == ["context7", "linear"])
        }
        #expect(String(decoding: try Data(contentsOf: config), as: UTF8.self).contains(secret))
        // OpenAccs remembers digests only.
        #expect(!String(decoding: try Data(contentsOf: home.paths.syncStateFile), as: UTF8.self).contains(secret))
        // B's backup holds what changed there and nothing else of its config.
        let backup = try #require(home.files(under: "Library/Application Support/OpenAccs/Backups").first { $0.hasSuffix("Windows/b/Data/claude_desktop_config.json") })
        let saved = home.json(at: home.paths.backupsDir.appending(path: backup))
        #expect(saved["coworkUserFilesPath"] == nil)
        #expect((saved["mcpServers"] as? [String: Any])?.keys.sorted() == ["linear"])
        #expect((saved["preferences"] as? [String: Any])?["menuBarEnabled"] as? Bool == true)
        #expect((saved["preferences"] as? [String: Any])?["epitaxyPrefs"] == nil)
    }

    @Test func pinsAndSettingsForOneWindowLandInOneSync() throws {
        let home = try TempHome()
        let main = home.window("main", account: mainAccount, isDefault: true)
        let b = home.window("b", account: otherAccount)
        try home.save(main, Settings(menuBar: false, folders: stoli))
        try home.save(b, Settings())
        // Both windows show one chat; only the main one pins it.
        let card: [String: Any] = ["sessionId": "local_chat", "cliSessionId": "chat-1", "cwd": "/code", "title": "Chat",
                                   "createdAt": 1, "lastActivityAt": 2]
        for window in [main, b] {
            let dir = try #require(window.cardsDir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: card).write(to: dir.appending(path: "local_chat.json"))
        }
        try home.write(".claude/projects/-code/chat-1.jsonl", "{\"type\":\"user\"}\n")
        try home.change(main, at: base) { prefs in
            prefs["starred-local-code-sessions"] = ["local_chat"]
            prefs["dframe-local-slice"] = ["pinnedOrder": ["code:local_chat"], "homeProjectsPinnedOrder": []]
        }
        #expect(ChromiumLocalStorage.set(PinList.storageValue(["local_chat"])!, for: PinList.storageKey, origin: PinList.origin, in: main.dataDir))

        let (plan, report) = try sync(home, [main, b], pins: true)

        #expect(plan.count(.pins, for: b.dataDir) == 1 && plan.count(.settings, for: b.dataDir) == 1)
        #expect(report.skipped == 0)
        #expect(PinList(dataDir: b.dataDir)?.ids == ["local_chat", "local_\(otherAccount)"])   // a pin of no known card stays
        #expect(home.folders(b) == stoli)
    }

    @Test func seedGivesANewWindowTheSettingsThatBelongToNoAccount() throws {
        let home = try TempHome()
        let main = home.window("main", account: mainAccount, isDefault: true)
        try home.save(main, Settings(fastMode: true, menuBar: false, folders: stoli, mcp: ["context7": ["command": "npx"]]))
        let new = home.url.appending(path: "Windows/new/Data", directoryHint: .isDirectory)

        try AppSettings.seed(new, from: main.dataDir)

        let seeded = home.json(at: new.appending(path: "claude_desktop_config.json"))
        #expect(Set(seeded.keys) == ["preferences", "mcpServers"])
        let preferences = try #require(seeded["preferences"] as? [String: Any])
        #expect(Set(preferences.keys) == ["sidebarMode", "menuBarEnabled", "epitaxyPrefs"])
        #expect(Set((preferences["epitaxyPrefs"] as? [String: Any] ?? [:]).keys) == ["starred-local-code-sessions"])

        // Without pin sync, a new window starts with no pins.
        let own = home.url.appending(path: "Windows/own/Data", directoryHint: .isDirectory)
        try AppSettings.seed(own, from: main.dataDir, pins: false)
        #expect(Set((home.json(at: own.appending(path: "claude_desktop_config.json"))["preferences"] as? [String: Any] ?? [:]).keys) == ["sidebarMode", "menuBarEnabled"])

        // Never over a file that is there, and nothing from a window without one.
        let b = home.window("b", account: otherAccount)
        let bConfig = try home.save(b, Settings())
        let bytes = try Data(contentsOf: bConfig)
        try AppSettings.seed(b.dataDir, from: main.dataDir)
        #expect(try Data(contentsOf: bConfig) == bytes)
        let empty = home.url.appending(path: "Windows/empty/Data", directoryHint: .isDirectory)
        try AppSettings.seed(empty, from: home.url.appending(path: "Windows/none/Data"))
        #expect(!FS.exists(empty.appending(path: "claude_desktop_config.json")))
    }
}
