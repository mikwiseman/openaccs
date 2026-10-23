import Darwin
import Foundation
import OpenAccsCore
import Testing
@testable import ClaudeKit

private let account = "11111111-1111-4111-8111-111111111111"
private let org = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

/// Every field a card may carry that is bound to the account that made it (DESIGN.md).
private var accountBound: [String: Any] { [
    "bridgeSessionIds": ["b1"], "bridgeSessionId": "b1", "cloudSessionId": "cse_1", "movedToCloud": false,
    "remoteControlEnabled": true, "steeredByRemoteClient": false, "envScopeId": "env_1",
    "remoteMcpServersConfig": ["linear": ["url": "https://mcp.linear.app"]], "withheldConnectorHosts": ["x.com"],
    "enabledMcpTools": ["a": true], "scheduledTaskId": "task_1", "startedFromEnvironmentId": "env_2",
    "emailAddress": "someone@example.com", "worktreePath": "/Users/x/proj/.claude/worktrees/w", "worktreeName": "w",
    "branch": "claude/w", "folderWorktrees": ["/a": "/b"], "keptDirtyWorktree": false, "worktreeLazy": true,
    "stagedTranscriptPath": "/tmp/t.jsonl", "importedFrom": "cli", "resumeConfirmed": true, "peerReceipts": [1],
    "peerInbound": [2], "peerMessaged": [3], "spawnedFrom": "s", "dispatchParentId": "d", "forkedFromSessionId": "f",
    "sessionPermissionUpdates": [["tool": "Bash"]], "alwaysAllowedReasons": ["r"], "cuAllowedApps": ["Finder"],
    "cuGrantFlags": 3, "chromeAllowedDomains": ["a.com"], "spawnSeed": "seed", "sshRemoteProcessId": 77,
    "pendingSystemReminder": "remember", "spaceId": "space_1", "publishedArtifacts": ["art_1"],
    "someFutureField": "unknown fields are not copied either",
] }

private let allowList: Set<String> = [
    "sessionId", "cliSessionId", "cwd", "originCwd", "title", "titleSource", "createdAt", "lastActivityAt",
    "isArchived", "isStarred", "model", "effort", "permissionMode", "completedTurns",
]

/// One Code-tab session: its card file name and its transcript id.
private struct Session {
    var sessionId = "local_" + UUID().uuidString.lowercased()
    var cli = UUID().uuidString.lowercased()
    var file: String { sessionId + ".json" }

    func card(title: String = "Fix the build", at lastActivityAt: Double = 1_760_000_000_000, _ extra: [String: Any] = [:]) -> [String: Any] {
        var card: [String: Any] = [
            "sessionId": sessionId, "cliSessionId": cli, "cwd": "/Users/x/proj", "originCwd": "/Users/x/proj",
            "title": title, "titleSource": "auto", "createdAt": 1_759_000_000_000, "lastActivityAt": lastActivityAt,
            "isArchived": false, "model": "claude-opus-4-5", "effort": "high", "permissionMode": "acceptEdits", "completedTurns": 4,
        ]
        card.merge(extra) { _, new in new }
        return card
    }
}

extension TempHome {
    fileprivate func profile(_ name: String) -> ClaudeProfile {
        ClaudeProfile(dataDir: url.appending(path: "Profiles/\(name)/Data", directoryHint: .isDirectory), isDefault: false, accountUuid: account, orgUuid: org)
    }

    @discardableResult
    fileprivate func card(_ profile: ClaudeProfile, _ fields: [String: Any], named name: String? = nil) throws -> URL {
        let dir = try #require(profile.cardsDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: name ?? "\(fields["sessionId"] as! String).json")
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: file)
        return file
    }

    fileprivate func transcript(_ session: Session, project: String = "-Users-x-proj") throws {
        try write(".claude/projects/\(project)/\(session.cli).jsonl", "{\"type\":\"user\"}\n")
    }

    fileprivate func cardFile(_ profile: ClaudeProfile, _ session: Session) -> URL {
        profile.cardsDir!.appending(path: session.file)
    }

    /// A profile's desktop config: the chats pinned in its sidebar (card sessionIds, in this order) and
    /// settings that are not OpenAccs's business, an MCP server key among them.
    @discardableResult
    fileprivate func pins(_ profile: ClaudeProfile, _ ids: [String]) throws -> URL {
        let config: [String: Any] = [
            "mcpServers": ["linear": ["command": "npx", "env": ["LINEAR_API_KEY": "lin_secret"]]],
            "preferences": ["ccNewTaskPrompt": "ask", "epitaxyPrefs": [
                "fastMode": true,
                "starred-local-code-sessions": Array(ids.reversed()),   // the sidebar orders them by pinnedOrder
                "dframe-local-slice": ["pinnedOrder": ["code:local_unpinned-long-ago"] + ids.map { "code:" + $0 }, "homeProjectsPinnedOrder": []],
            ]],
        ]
        let file = profile.dataDir.appending(path: "claude_desktop_config.json")
        try FileManager.default.createDirectory(at: profile.dataDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]).write(to: file)
        return file
    }

    /// The sessionIds a profile's sidebar shows pinned, in order.
    fileprivate func pinned(_ profile: ClaudeProfile) -> [String] {
        PinList(dataDir: profile.dataDir)?.ids ?? []
    }

    /// Card file names in a profile's current folder (everything, including tombstones).
    fileprivate func names(_ profile: ClaudeProfile) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: profile.cardsDir!.path)) ?? []).sorted()
    }

    /// Files under Backups, relative to it.
    fileprivate var backups: [String] { files(under: "Library/Application Support/OpenAccs/Backups") }

    /// Anything that looks like a temp file, anywhere in the home (hidden files included).
    fileprivate var leftovers: [String] {
        (FileManager.default.subpaths(atPath: url.path) ?? []).filter { path in
            let name = (path as NSString).lastPathComponent
            return name.hasSuffix(".tmp") || name.hasSuffix(".partial") || name.hasPrefix(".openaccs-")
        }
    }

    fileprivate var syncState: SyncState { (try? SyncState.load(paths.syncStateFile)) ?? SyncState() }
}

/// A CardSync whose "running Claude" list is fixed by the test.
private func cardSync(_ home: TempHome, running: [(ClaudeProfile, Date)] = [], unreadable: Bool = false) -> CardSync {
    var processes = running.enumerated().map { i, item in claudeProcess(pid: pid_t(100 + i), dataDir: item.0.dataDir, launched: item.1) }
    if unreadable { processes.append(ClaudeProcess(pid: 99, arguments: nil, launchDate: nil)) }
    let fixed = processes
    return CardSync(claude: ClaudeProfiles(paths: home.paths, processes: { fixed }))
}

@discardableResult
private func sync(_ home: TempHome, _ profiles: [ClaudeProfile], running: [(ClaudeProfile, Date)] = []) throws -> (SyncPlan, SyncReport) {
    let sync = cardSync(home, running: running)
    let plan = try sync.plan(profiles: profiles, running: Set(running.map(\.0.dataDir)))
    return (plan, try sync.apply(plan))
}

@Suite struct CardSyncTests {
    @Test func stoppedProfilesGetEachOthersSessionsThroughTheAllowList() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s1 = Session(), s2 = Session()
        try home.card(a, s1.card(title: "From A", ["permissionMode": "bypassPermissions"]).merging(accountBound) { old, _ in old })
        try home.card(b, s2.card(title: "From B", ["permissionMode": "plan"]).merging(accountBound) { old, _ in old })
        try home.transcript(s1)
        try home.transcript(s2, project: "-Users-x-other")

        let (plan, report) = try sync(home, [a, b])

        #expect(plan.count(.create) == 2)
        #expect(plan.count(.create, for: a.dataDir) == 1)
        #expect(plan.count(.update) == 0 && plan.count(.remove) == 0)
        #expect(report.created == 2 && report.skipped == 0 && report.failures.isEmpty)
        #expect(home.names(a) == [s1.file, s2.file].sorted())
        #expect(home.names(b) == [s1.file, s2.file].sorted())

        // A's session in B: file name == sessionId + ".json", only allow-listed fields, the chat's own
        // permission mode (the same person chose it; dropping it reopened chats in Manual).
        let copyOfS1 = home.json(at: home.cardFile(b, s1))
        #expect(copyOfS1["sessionId"] as? String == s1.sessionId)
        #expect(Set(copyOfS1.keys) == allowList.subtracting(["isStarred"]))
        #expect((copyOfS1 as NSDictionary).isEqual(to: s1.card(title: "From A", ["permissionMode": "bypassPermissions"])))

        let copyOfS2 = home.json(at: home.cardFile(a, s2))
        #expect(Set(copyOfS2.keys) == allowList.subtracting(["isStarred"]))
        #expect(copyOfS2["permissionMode"] as? String == "plan")
        #expect(copyOfS2["title"] as? String == "From B")

        // The originals are untouched and OpenAccs remembers what it made.
        #expect(Set(home.json(at: home.cardFile(a, s1)).keys).isSuperset(of: accountBound.keys))
        #expect(Set(home.syncState.created.map(\.file)) == [home.cardFile(b, s1).path, home.cardFile(a, s2).path])
        #expect(home.leftovers.isEmpty)
    }

    @Test func secondRunIsANoOp() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B"), c = home.profile("C")
        let s1 = Session(), s2 = Session()
        try home.card(a, s1.card(at: 2_000))
        try home.card(b, s2.card(at: 1_000))
        try home.card(c, s1.card(title: "Older title", at: 1_000))
        for s in [s1, s2] { try home.transcript(s) }
        try sync(home, [a, b, c])
        let state = try Data(contentsOf: home.paths.syncStateFile)
        let snapshot = home.files(under: "Profiles").map { ($0, try? Data(contentsOf: home.url.appending(path: "Profiles/\($0)"))) }

        let (plan, report) = try sync(home, [a, b, c])

        #expect(plan.isEmpty)
        #expect(report == SyncReport())
        #expect(try Data(contentsOf: home.paths.syncStateFile) == state)
        #expect(home.files(under: "Profiles").map { ($0, try? Data(contentsOf: home.url.appending(path: "Profiles/\($0)"))) }.elementsEqual(snapshot) { $0 == $1 })
        #expect(home.leftovers.isEmpty)
    }

    @Test func sessionsWithoutATranscriptAreNotCopied() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let kept = Session(), noTranscript = Session(), linkedTranscript = Session(), elsewhere = Session()
        for s in [kept, noTranscript, linkedTranscript, elsewhere] { try home.card(a, s.card()) }
        try home.transcript(kept)
        // A transcript that is only a symlink does not count.
        try home.write("outside/\(linkedTranscript.cli).jsonl", "{}\n")
        try FileManager.default.createDirectory(at: home.url.appending(path: ".claude/projects/-Users-x-proj"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.url.appending(path: ".claude/projects/-Users-x-proj/\(linkedTranscript.cli).jsonl"),
            withDestinationURL: home.url.appending(path: "outside/\(linkedTranscript.cli).jsonl"))
        // A transcript outside <home>/.claude/projects (e.g. a legacy CLAUDE_CONFIG_DIR) does not count.
        try home.write("legacy/projects/-Users-x-proj/\(elsewhere.cli).jsonl", "{}\n")

        let (plan, _) = try sync(home, [a, b])

        #expect(plan.operations.map(\.cliSessionId) == [kept.cli])
        #expect(home.names(b) == [kept.file])
    }

    @Test func takenSessionIdGetsAFreshLocalId() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s1 = Session(), other = Session()
        try home.card(a, s1.card())
        // B already has a file with s1's name, holding a different session.
        let squatter = try home.card(b, other.card(title: "B's own"), named: s1.file)
        let before = try Data(contentsOf: squatter)
        for s in [s1, other] { try home.transcript(s) }

        let (_, report) = try sync(home, [a, b])

        #expect(report.created == 2)  // s1 into B, other into A
        #expect(try Data(contentsOf: squatter) == before)
        let fresh = home.names(b).filter { $0 != s1.file }
        #expect(fresh.count == 1)
        let name = try #require(fresh.first)
        let copy = home.json(at: b.cardsDir!.appending(path: name))
        #expect(copy["cliSessionId"] as? String == s1.cli)
        #expect(name == "\(copy["sessionId"] as? String ?? "?").json")
        #expect(name.hasPrefix("local_") && name != s1.file)
        #expect(UUID(uuidString: String(name.dropFirst("local_".count).dropLast(".json".count))) != nil)
        // `other` keeps its own sessionId in A (no clash there).
        #expect(home.json(at: a.cardsDir!.appending(path: other.file))["cliSessionId"] as? String == other.cli)
    }

    @Test func runningProfileGetsNewCardsButNoEdits() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let shared = Session(), fromA = Session(), deleted = Session()
        try home.card(a, shared.card(title: "New title", at: 2_000))
        try home.card(a, fromA.card())
        try home.card(a, deleted.card())
        for s in [shared, fromA, deleted] { try home.transcript(s) }
        try sync(home, [a, b])                                          // B gets copies of all three
        try home.card(a, shared.card(title: "Newer title", at: 3_000))  // A moves on: B's copy is now older
        let older = home.cardFile(b, shared)
        let staleBytes = try Data(contentsOf: older)
        try FileManager.default.removeItem(at: home.cardFile(a, deleted))
        try home.write("Profiles/A/Data/claude-code-sessions/\(account)/\(org)/deleted_\(deleted.cli)", "1760000000000")
        let late = Session()
        try home.card(a, late.card())
        try home.transcript(late)

        let launched = Date(timeIntervalSince1970: 1_000)
        let (plan, report) = try sync(home, [a, b], running: [(b, launched)])

        #expect(plan.operations.map(\.kind) == [.create])
        #expect(plan.operations.first?.cliSessionId == late.cli)
        #expect(plan.count(.create, for: b.dataDir) == 1)
        #expect(report.created == 1)
        #expect(FS.isRegularFile(home.cardFile(b, late)))
        #expect(try Data(contentsOf: older) == staleBytes)
        #expect(FS.isRegularFile(home.cardFile(b, deleted)))
        #expect(home.backups.isEmpty)
        #expect(home.leftovers.isEmpty)
    }

    @Test func applyRechecksRunningAndChangedFilesBeforeEditing() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s = Session()
        try home.card(a, s.card(title: "New", at: 2_000))
        let stale = try home.card(b, s.card(title: "Old", at: 1_000))
        try home.transcript(s)
        let staleBytes = try Data(contentsOf: stale)

        let plan = try cardSync(home).plan(profiles: [a, b], running: [])
        #expect(plan.operations.map(\.kind) == [.update])

        // B started between plan and apply.
        let whileRunning = try cardSync(home, running: [(b, Date())]).apply(plan)
        #expect(whileRunning.updated == 0 && whileRunning.skipped == 1)
        // Some Claude process could not be mapped: B may be running.
        let unknown = try cardSync(home, unreadable: true).apply(plan)
        #expect(unknown.updated == 0 && unknown.skipped == 1)
        #expect(try Data(contentsOf: stale) == staleBytes)

        // The card changed on disk after planning.
        let edited = try home.card(b, s.card(title: "Renamed in B", at: 1_500))
        let editedBytes = try Data(contentsOf: edited)
        let changed = try cardSync(home).apply(plan)
        #expect(changed.updated == 0 && changed.skipped == 1)
        #expect(try Data(contentsOf: edited) == editedBytes)
        #expect(home.backups.isEmpty)
    }

    @Test func stoppedProfileWithAnOlderCardGetsTitleAndActivityRefreshed() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s = Session()
        try home.card(a, s.card(title: "Ship v2", at: 2_000, ["titleSource": "user", "model": "opus", "emailAddress": "a@example.com"]))
        let mine = try home.card(b, s.card(title: "Untitled", at: 1_000, ["model": "sonnet", "emailAddress": "b@example.com", "worktreePath": "/b/wt"]))
        try home.transcript(s)
        let oldBytes = try Data(contentsOf: mine)

        let (plan, report) = try sync(home, [a, b])

        #expect(plan.operations.map(\.kind) == [.update])
        #expect(plan.operations.first?.file.path == mine.path)
        #expect(report.updated == 1)
        let card = home.json(at: mine)
        #expect(card["title"] as? String == "Ship v2")
        #expect(card["titleSource"] as? String == "user")
        #expect(JSON.double(card["lastActivityAt"]) == 2_000)
        // Chat settings follow where the chat ran last; everything else is B's and stays B's.
        #expect(card["model"] as? String == "opus")
        #expect(card["emailAddress"] as? String == "b@example.com")
        #expect(card["worktreePath"] as? String == "/b/wt")
        // The old card is in Backups, byte for byte.
        let suffix = "Profiles/B/Data/claude-code-sessions/\(account)/\(org)/\(s.file)"
        let backup = try #require(home.backups.first { $0.hasSuffix(suffix) })
        #expect(backup.contains(" card-sync/"))
        #expect(try Data(contentsOf: home.paths.backupsDir.appending(path: backup)) == oldBytes)
        // A (the freshest copy) is untouched.
        #expect(home.json(at: home.cardFile(a, s))["emailAddress"] as? String == "a@example.com")
        #expect(home.leftovers.isEmpty)
    }

    @Test func deletedSessionIsNeverRecreatedAndOurCopiesMoveToBackups() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B"), c = home.profile("C"), d = home.profile("D"), e = home.profile("E")
        let s = Session(), keep = Session()
        try home.card(a, s.card())
        try home.card(a, keep.card())
        for x in [s, keep] { try home.transcript(x) }
        try sync(home, [a, b, c, d])  // B, C, D get OpenAccs-made copies
        // E has its own card for s (not made by OpenAccs).
        let own = try home.card(e, s.card())
        let copyInB = home.cardFile(b, s)
        let copyBytes = try Data(contentsOf: copyInB)
        // The user deletes s in A: Claude removes the card and writes a tombstone.
        try FileManager.default.removeItem(at: home.cardFile(a, s))
        try home.write("Profiles/A/Data/claude-code-sessions/\(account)/\(org)/deleted_\(s.cli)", "1760000000000")

        let (plan, report) = try sync(home, [a, b, c, d, e], running: [(d, Date())])

        #expect(plan.tombstones == [s.cli])
        #expect(!plan.operations.contains { $0.kind == .create && $0.cliSessionId == s.cli })
        #expect(Set(plan.operations.filter { $0.kind == .remove }.map(\.dataDir)) == [b.dataDir, c.dataDir])
        #expect(report.removed == 2)
        #expect(!FS.exists(copyInB) && !FS.exists(home.cardFile(c, s)))
        #expect(!FS.exists(home.cardFile(a, s)))
        #expect(FS.isRegularFile(home.cardFile(d, s)))  // D runs: left alone for now
        #expect(FS.isRegularFile(own))                   // never OpenAccs's to remove
        let moved = try #require(home.backups.first { $0.hasSuffix("Profiles/B/Data/claude-code-sessions/\(account)/\(org)/\(s.file)") })
        #expect(try Data(contentsOf: home.paths.backupsDir.appending(path: moved)) == copyBytes)
        #expect(home.syncState.tombstones == [s.cli])
        #expect(!home.syncState.created.contains { $0.file == copyInB.path })

        // Once D stops, its copy goes too; nothing ever comes back, even after the tombstone file is gone.
        try FileManager.default.removeItem(at: a.cardsDir!.appending(path: "deleted_\(s.cli)"))
        let (later, laterReport) = try sync(home, [a, b, c, d, e, home.profile("F")])
        #expect(later.operations.filter { $0.cliSessionId == s.cli }.map(\.kind) == [.remove])
        #expect(laterReport.removed == 1)
        #expect(!FS.exists(home.cardFile(d, s)))
        #expect(!home.names(home.profile("F")).contains(s.file))
        #expect(home.names(home.profile("F")).contains(keep.file))
        #expect(FS.isRegularFile(own))
        #expect(try sync(home, [a, b, c, d, e, home.profile("F")]).0.isEmpty)
        #expect(home.leftovers.isEmpty)
    }

    @Test func cardTheUserDeletedIsNoticedAndNotRecreated() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s = Session()
        try home.card(a, s.card())
        try home.transcript(s)
        try sync(home, [a, b])
        // The user deletes OpenAccs's copy in B; no tombstone file (e.g. removed in Finder).
        try FileManager.default.removeItem(at: home.cardFile(b, s))

        let (plan, report) = try sync(home, [a, b])

        #expect(plan.operations.isEmpty)
        #expect(plan.tombstones == [s.cli])
        #expect(report == SyncReport())
        #expect(!FS.exists(home.cardFile(b, s)))
        #expect(FS.isRegularFile(home.cardFile(a, s)))  // the original stays
        #expect(home.syncState.tombstones == [s.cli])
        #expect(try sync(home, [a, b]).0.isEmpty)
    }

    @Test func neverWritesThroughASymlinkedOrgFolder() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B"), c = home.profile("C")
        let s = Session()
        try home.card(a, s.card())
        try home.transcript(s)
        // B's org folder and C's account folder are links to somewhere else.
        let elsewhere = home.url.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere.appending(path: "org"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.cardsDir!.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: b.cardsDir!, withDestinationURL: elsewhere.appending(path: "org"))
        try FileManager.default.createDirectory(at: c.dataDir.appending(path: "claude-code-sessions"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: c.dataDir.appending(path: "claude-code-sessions/\(account)"), withDestinationURL: elsewhere)

        let sync = cardSync(home)
        let plan = try sync.plan(profiles: [a, b, c], running: [])
        #expect(plan.operations.isEmpty)

        // Even a plan made by hand (or before the link appeared) is refused at apply time.
        let data = Data(#"{"sessionId":"x"}"#.utf8)
        let forged = SyncPlan(operations: [
            SyncOperation(kind: .create, dataDir: b.dataDir, file: b.cardsDir!.appending(path: s.file), cliSessionId: s.cli, contents: data),
            SyncOperation(kind: .create, dataDir: c.dataDir, file: c.cardsDir!.appending(path: s.file), cliSessionId: s.cli, contents: data),
        ], tombstones: [])
        let report = try sync.apply(forged)
        #expect(report.created == 0 && report.skipped == 2)
        #expect(home.files(under: "Elsewhere").isEmpty)
        #expect(home.syncState.created.isEmpty)
    }

    @Test func priorTranscriptIdsAreTheSameSession() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B"), c = home.profile("C")
        let first = Session(), cleared = Session(), current = Session()
        // A's card moved on twice (/clear, then a fork): first → cleared → current.
        try home.card(a, current.card(["priorCliSessionIds": [first.cli, current.cli], "preClearCliSessionId": cleared.cli]))
        // B still has a card for the first transcript.
        try home.card(b, first.card(title: "Old", at: 1))
        try FileManager.default.createDirectory(at: c.cardsDir!, withIntermediateDirectories: true)
        for s in [first, cleared, current] { try home.transcript(s) }

        let (plan, _) = try sync(home, [a, b, c])

        // Only the current transcript is a session; its old ids are never copied anywhere.
        #expect(Set(plan.operations.map(\.cliSessionId)) == [current.cli])
        #expect(plan.count(.create, for: a.dataDir) == 0)
        #expect(plan.count(.create, for: b.dataDir) == 1)
        #expect(plan.count(.create, for: c.dataDir) == 1)
        #expect(home.names(c) == [current.file])
        #expect(home.names(a) == [current.file])
    }

    @Test func clearedCardWithoutATranscriptIdStillClaimsItsOldOne() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B"), c = home.profile("C")
        let s = Session()
        try home.card(a, s.card(at: 1_000))
        // The user ran /clear in B: Claude saves the card without cliSessionId until the next message.
        var cleared = s.card(at: 2_000, ["priorCliSessionIds": [s.cli], "preClearCliSessionId": s.cli])
        cleared["cliSessionId"] = nil
        let clearedFile = try home.card(b, cleared)
        let clearedBytes = try Data(contentsOf: clearedFile)
        try FileManager.default.createDirectory(at: c.cardsDir!, withIntermediateDirectories: true)
        try home.transcript(s)
        let launched = Date().addingTimeInterval(-3600)

        let plan = try cardSync(home, running: [(b, launched)]).plan(profiles: [a, b, c], running: [b.dataDir])

        // B's cleared card stands for the old transcript: no duplicate in B, and it is nobody's source now.
        #expect(plan.count(.create, for: b.dataDir) == 0)
        #expect(plan.isEmpty)
        #expect(cardSync(home, running: [(b, launched)]).pendingCount(for: b, among: [a, b, c]) == 0)
        // Stopped, B's cleared card is never edited or removed.
        #expect(try sync(home, [a, b, c]).0.isEmpty)
        #expect(try Data(contentsOf: clearedFile) == clearedBytes)
        #expect(home.names(c).isEmpty)
    }

    @Test func titlesSomeoneChoseAreNeverReplaced() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B"), c = home.profile("C"), d = home.profile("D")
        let named = Session(), auto = Session()
        // A has the freshest copies: an auto title for `auto`, a user rename for `named`.
        try home.card(a, named.card(title: "Ship v2", at: 3_000, ["titleSource": "user"]))
        try home.card(a, auto.card(title: "Fresh auto title", at: 3_000))
        // B renamed both by hand; C had Claude rename `auto` with its session tool; D has only auto titles.
        let bNamed = try home.card(b, named.card(title: "My name", at: 1_000, ["titleSource": "user"]))
        let bAuto = try home.card(b, auto.card(title: "Mine too", at: 1_000, ["titleSource": "user"]))
        let cAuto = try home.card(c, auto.card(title: "Named by Claude", at: 1_000, ["titleSource": "tool"]))
        let dNamed = try home.card(d, named.card(title: "Old auto title", at: 1_000))
        for s in [named, auto] { try home.transcript(s) }

        let (_, report) = try sync(home, [a, b, c, d])

        #expect(report.updated == 4)
        for (file, title, source) in [(bNamed, "My name", "user"), (bAuto, "Mine too", "user"), (cAuto, "Named by Claude", "tool")] {
            let card = home.json(at: file)
            #expect(card["title"] as? String == title)
            #expect(card["titleSource"] as? String == source)
            #expect(JSON.double(card["lastActivityAt"]) == 3_000)  // activity still moves on
        }
        // A user-set title may replace an auto one.
        let card = home.json(at: dNamed)
        #expect(card["title"] as? String == "Ship v2")
        #expect(card["titleSource"] as? String == "user")
    }

    @Test func chatSettingsFollowTheLastChange() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s = Session()
        try home.card(a, s.card(at: 2_000))
        try home.card(b, s.card(at: 2_000))
        try home.transcript(s)
        try sync(home, [a, b])   // both agree: not archived, acceptEdits, high

        // In B: archived, switched to Auto and Max (the app rewrites its card).
        try home.card(b, s.card(at: 2_000, ["isArchived": true, "permissionMode": "auto", "autoChosenInApp": true, "effort": "max"]))
        try sync(home, [a, b])
        let inA = home.json(at: home.cardFile(a, s))
        #expect(inA["isArchived"] as? Bool == true)
        #expect(inA["permissionMode"] as? String == "auto")
        #expect(inA["autoChosenInApp"] as? Bool == true)
        #expect(inA["effort"] as? String == "max")

        // Then unarchived in A: B follows, and nothing else moves back.
        try home.card(a, inA.merging(["isArchived": false]) { _, new in new })
        try sync(home, [a, b])
        let inB = home.json(at: home.cardFile(b, s))
        #expect(inB["isArchived"] as? Bool == false)
        #expect(inB["permissionMode"] as? String == "auto")
        #expect(inB["effort"] as? String == "max")
        #expect(try sync(home, [a, b]).0.isEmpty)
    }

    @Test func anOpenWindowKeepsItsCopyUntilItRestartsAndNeverOverrulesTheChange() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s = Session()
        try home.card(a, s.card())
        let inB = try home.card(b, s.card())
        try home.transcript(s)
        try sync(home, [a, b])
        try home.card(a, s.card(["effort": "max"]))   // changed in A while B is open
        let open = [(b, Date())]

        let (plan, _) = try sync(home, [a, b], running: open)
        #expect(home.json(at: inB)["effort"] as? String == "high")
        #expect(plan.waiting(in: b.cardsDir!) == 1)
        // B's old value is not a change of its own: A's choice stays.
        try sync(home, [a, b], running: open)
        #expect(home.json(at: home.cardFile(a, s))["effort"] as? String == "max")
        // B closes: it catches up.
        try sync(home, [a, b])
        #expect(home.json(at: inB)["effort"] as? String == "max")
    }

    @Test func firstSyncArchivesWhatEveryWindowArchivedAndTakesSettingsFromWhereTheChatRanLast() throws {
        let home = try TempHome()
        var a = home.profile("A")
        a.isConfirmed = true
        let b = home.profile("B")
        // An account signed in to A before: no window shows its folder now.
        let old = ClaudeProfile(dataDir: a.dataDir, isDefault: false, accountUuid: "33333333-3333-4333-8333-333333333333", orgUuid: org)
        let s = Session(), stale = Session()
        try home.card(a, s.card(at: 1_000, ["isArchived": true, "effort": "high"]))
        try home.card(b, s.card(at: 2_000, ["isArchived": true, "effort": "max", "permissionMode": "bypassPermissions"]))
        let oldS = try home.card(old, s.card(at: 500, ["effort": "low"]))
        // Archived only in that old folder: from long ago.
        try home.card(a, stale.card())
        try home.card(b, stale.card())
        let oldStale = try home.card(old, stale.card(["isArchived": true]))
        for x in [s, stale] { try home.transcript(x) }
        let open = [(a, Date()), (b, Date())]

        let (plan, _) = try sync(home, [a, b], running: open)

        let card = home.json(at: oldS)
        #expect(card["isArchived"] as? Bool == true)
        #expect(card["effort"] as? String == "max")
        #expect(card["permissionMode"] as? String == "bypassPermissions")
        #expect(home.json(at: oldStale)["isArchived"] as? Bool == false)
        #expect(plan.waiting(in: a.cardsDir!) == 1)   // effort and mode differ
        #expect(plan.waiting(in: b.cardsDir!) == 0)
    }

    @Test func everyAccountFolderOfAProfileStaysCompleteEvenWhileItRuns() throws {
        let home = try TempHome()
        let b = home.profile("B")
        var a = home.profile("A")
        a.isConfirmed = true   // Claude's log says which folder A shows
        let earlier = ClaudeProfile(dataDir: a.dataDir, isDefault: false, accountUuid: "22222222-2222-4222-8222-222222222222", orgUuid: org)
        let s = Session(), t = Session()
        try home.card(a, s.card(title: "Old", at: 1_000))
        let inEarlier = try home.card(earlier, s.card(title: "Old", at: 1_000))
        try home.card(b, s.card(title: "New", at: 2_000, ["effort": "max"]))
        try home.card(b, t.card())
        for x in [s, t] { try home.transcript(x) }
        let current = home.cardFile(a, s)
        let currentBytes = try Data(contentsOf: current)

        let (plan, _) = try sync(home, [a, b], running: [(a, Date())])

        // The account A shows now is loaded: new cards only. The one signed in there before is not.
        #expect(try Data(contentsOf: current) == currentBytes)
        #expect(home.json(at: inEarlier)["title"] as? String == "New")
        #expect(home.json(at: inEarlier)["effort"] as? String == "max")
        #expect(FS.isRegularFile(home.cardFile(a, t)))
        #expect(FS.isRegularFile(earlier.cardsDir!.appending(path: t.file)))
        #expect(plan.waiting(in: a.cardsDir!) == 1)
        #expect(plan.waiting(in: earlier.cardsDir!) == 0)
    }

    @Test func whileItRunsAProfileWhoseFolderIsAGuessGetsNewCardsOnly() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")   // no log line: A's folder is a guess
        let other = ClaudeProfile(dataDir: a.dataDir, isDefault: false, accountUuid: "44444444-4444-4444-8444-444444444444", orgUuid: org)
        let s = Session(), t = Session()
        let maybeLoaded = try home.card(other, s.card(title: "Old", at: 1_000))
        try home.card(a, s.card(title: "Old", at: 1_000))
        try home.card(b, s.card(title: "New", at: 2_000, ["effort": "max"]))
        try home.card(b, t.card())
        for x in [s, t] { try home.transcript(x) }
        let bytes = try Data(contentsOf: maybeLoaded)

        let (plan, _) = try sync(home, [a, b], running: [(a, Date())])

        #expect(try Data(contentsOf: maybeLoaded) == bytes)
        #expect(!plan.operations.contains { $0.kind == .update && $0.dataDir == a.dataDir })
        #expect(plan.operations.filter { $0.dataDir == a.dataDir }.allSatisfy { $0.requiresStopped })
        #expect(FS.isRegularFile(other.cardsDir!.appending(path: t.file)))   // new cards are still fine
    }

    @Test func firstSyncAfterUpgradeTrustsClaudesOwnCopyOverAnOldOneOpenAccsMade() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s = Session()
        try home.card(a, s.card(at: 2_000))
        try home.transcript(s)
        try sync(home, [a, b])   // B gets OpenAccs's copy
        // Later, in A: Auto and Max, without a new message. B's copy is written after that (0.2 refreshed it).
        try home.card(a, s.card(at: 2_000, ["permissionMode": "auto", "autoChosenInApp": true, "effort": "max"]))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: home.cardFile(b, s).path)
        // 0.2 kept no merge history.
        var state = home.syncState
        state.settings = [:]
        state.seen = [:]
        try state.save(to: home.paths.syncStateFile)

        try sync(home, [a, b])

        let copy = home.json(at: home.cardFile(b, s))
        #expect(copy["permissionMode"] as? String == "auto")
        #expect(copy["autoChosenInApp"] as? Bool == true)
        #expect(copy["effort"] as? String == "max")
        #expect(home.json(at: home.cardFile(a, s))["permissionMode"] as? String == "auto")
    }

    @Test func aChatMissingFromOneSyncKeepsItsHistory() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s = Session()
        try home.card(a, s.card(["isArchived": true]))
        try home.card(b, s.card(["isArchived": true]))
        try home.transcript(s)
        try sync(home, [a, b])
        try home.card(a, s.card(["isArchived": false]))   // unarchived in A while B is open
        let open = [(b, Date())]
        try sync(home, [a, b], running: open)
        // For one sync the chat isn't there (its transcript was moved away).
        let transcript = home.url.appending(path: ".claude/projects/-Users-x-proj/\(s.cli).jsonl")
        let aside = home.url.appending(path: "aside.jsonl")
        try FileManager.default.moveItem(at: transcript, to: aside)
        try sync(home, [a, b], running: open)
        try FileManager.default.moveItem(at: aside, to: transcript)

        try sync(home, [a, b], running: open)

        #expect(home.json(at: home.cardFile(a, s))["isArchived"] as? Bool == false)
    }

    @Test func newCopiesKeepTheFlagsThatGoWithTheirMode() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B"), c = home.profile("C")
        let s = Session()
        try home.card(a, s.card(["permissionMode": "auto", "autoChosenInApp": true]))
        try home.transcript(s)
        try sync(home, [a, b])
        #expect(home.json(at: home.cardFile(b, s))["autoChosenInApp"] as? Bool == true)
        // An old copy with the same mode but without the flag, newer on disk, doesn't strip it from the others.
        try home.card(c, s.card(["permissionMode": "auto"]))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: home.cardFile(c, s).path)
        try sync(home, [a, b, c])
        #expect(home.json(at: home.cardFile(a, s))["autoChosenInApp"] as? Bool == true)
        #expect(home.json(at: home.cardFile(c, s))["autoChosenInApp"] as? Bool == true)
    }

    @Test func onlyRealChangesAreBackedUp() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s = Session()
        try home.card(a, s.card(at: 2_000))
        try home.card(b, s.card(at: 1_000))
        try home.transcript(s)
        try sync(home, [a, b])   // B's card only moves on in time: no backup
        #expect(JSON.double(home.json(at: home.cardFile(b, s))["lastActivityAt"]) == 2_000)
        #expect(home.backups.isEmpty)
        try home.card(a, s.card(at: 2_000, ["isArchived": true]))
        try sync(home, [a, b])   // archiving is a real change: backed up
        #expect(home.backups.count == 1)
    }

    @Test func everyWindowsSidebarPinsTheSameChats() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s1 = Session(), s2 = Session()
        try home.card(a, s1.card())
        try home.card(b, s1.card())
        try home.card(a, s2.card())
        try home.card(b, s2.card(["sessionId": "local_b2"]))   // B knows s2 by another card name
        for s in [s1, s2] { try home.transcript(s) }
        try home.pins(a, [s1.sessionId])
        let configB = try home.pins(b, [])

        try sync(home, [a, b])

        #expect(home.pinned(b) == [s1.sessionId])
        // Nothing else in B's config changes, and it stays private.
        let config = home.json(at: configB)
        let linear = (config["mcpServers"] as? [String: Any])?["linear"] as? [String: Any]
        #expect(linear?["env"] as? [String: String] == ["LINEAR_API_KEY": "lin_secret"])
        let preferences = config["preferences"] as? [String: Any]
        #expect(preferences?["ccNewTaskPrompt"] as? String == "ask")
        let prefs = preferences?["epitaxyPrefs"] as? [String: Any]
        #expect(prefs?["fastMode"] as? Bool == true)
        #expect((prefs?["dframe-local-slice"] as? [String: Any])?["pinnedOrder"] as? [String] == ["code:local_unpinned-long-ago", "code:\(s1.sessionId)"])
        #expect(try FileManager.default.attributesOfItem(atPath: configB.path)[.posixPermissions] as? Int == 0o600)
        // The backup holds B's old pins only, never the rest of its config.
        let backup = try #require(home.backups.first { $0.hasSuffix("Profiles/B/Data/claude_desktop_config.json") })
        let saved = home.json(at: home.paths.backupsDir.appending(path: backup))
        #expect(saved["mcpServers"] == nil)
        #expect(((saved["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any])?["starred-local-code-sessions"] as? [String] == [])
        // Cards are not where pins live: they are left alone.
        #expect(home.json(at: home.cardFile(b, s1))["isStarred"] == nil)

        // Unpinned in A, s2 pinned in B: both windows follow.
        try home.pins(a, [])
        try home.pins(b, [s1.sessionId, "local_b2"])
        try sync(home, [a, b])
        #expect(home.pinned(a) == [s2.sessionId])
        #expect(home.pinned(b) == ["local_b2"])
        #expect(try sync(home, [a, b]).0.isEmpty)
    }

    @Test func anOpenWindowGetsItsPinsWhenItCloses() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s = Session()
        try home.card(a, s.card())
        try home.card(b, s.card())
        try home.transcript(s)
        try home.pins(a, [])
        let configB = try home.pins(b, [])
        try sync(home, [a, b])
        try home.pins(a, [s.sessionId])   // pinned in A while B is open
        let bytes = try Data(contentsOf: configB)
        let open = [(b, Date())]

        let (plan, _) = try sync(home, [a, b], running: open)
        #expect(try Data(contentsOf: configB) == bytes)   // Claude keeps its config in memory while it runs
        #expect(plan.waiting(in: b.cardsDir!) == 1)
        // B's old list is not an unpin of its own: A's pin stays.
        try sync(home, [a, b], running: open)
        #expect(home.pinned(a) == [s.sessionId])
        // B closes: it catches up.
        try sync(home, [a, b])
        #expect(home.pinned(b) == [s.sessionId])
    }

    @Test func firstSyncKeepsEveryPinInTheOrderOfTheWindowChangedLast() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s1 = Session(), s2 = Session(), s3 = Session()
        for s in [s1, s2, s3] {
            try home.card(a, s.card())
            try home.card(b, s.card())
            try home.transcript(s)
        }
        try home.pins(a, [s3.sessionId])
        let configB = try home.pins(b, [s2.sessionId, s1.sessionId])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: a.dataDir.appending(path: "claude_desktop_config.json").path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30)], ofItemAtPath: configB.path)

        try sync(home, [a, b])
        let all = [s2.sessionId, s1.sessionId, s3.sessionId]
        #expect(home.pinned(a) == all)
        #expect(home.pinned(b) == all)

        // Reordered in A: B follows.
        try home.pins(a, [s3.sessionId, s2.sessionId, s1.sessionId])
        try sync(home, [a, b])
        #expect(home.pinned(b) == [s3.sessionId, s2.sessionId, s1.sessionId])
    }

    @Test func pinsOfCardsOpenAccsDoesNotKnowStayAndDeletedChatsAreUnpinned() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B"), c = home.profile("C")
        let s = Session(), gone = Session()
        for x in [s, gone] {
            try home.card(a, x.card())
            try home.card(b, x.card())
            try home.transcript(x)
        }
        try home.pins(a, [s.sessionId, gone.sessionId, "local_not-a-card"])
        try home.pins(b, [])
        try home.write("Profiles/B/Data/claude-code-sessions/\(account)/\(org)/deleted_\(gone.cli)", "1760000000000")

        try sync(home, [a, b, c])

        #expect(home.pinned(a) == [s.sessionId, "local_not-a-card"])
        #expect(home.pinned(b) == [s.sessionId])
        // A profile without a config yet gets none: Claude makes it at first launch.
        #expect(!FS.exists(c.dataDir.appending(path: "claude_desktop_config.json")))
    }

    @Test func cardsAreReadOnceUntilTheyChangeAndKeepOnlyChatFieldsInMemory() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s = Session()
        // Claude writes hundreds of KB of account data into each card; a sync never needs it.
        let big: [String: Any] = ["remoteMcpServersConfig": ["linear": String(repeating: "x", count: 200_000)]]
        try home.card(a, s.card(title: "New", at: 2_000, big))
        let mine = try home.card(b, s.card(title: "Old", at: 1_000, big))
        try home.transcript(s)
        let sync = cardSync(home)

        _ = try sync.apply(sync.plan(profiles: [a, b], running: []))
        #expect(sync.cache.reads == 2)
        #expect(home.json(at: mine)["title"] as? String == "New")
        #expect(NSDictionary(dictionary: home.json(at: mine)["remoteMcpServersConfig"] as? [String: Any] ?? [:])
            .isEqual(to: big["remoteMcpServersConfig"] as! [String: Any]))
        _ = try sync.plan(profiles: [a, b], running: [])   // only B's rewritten card is read again
        #expect(sync.cache.reads == 3)
        let plan = try sync.plan(profiles: [a, b], running: [])
        _ = sync.pendingCount(for: b, among: [a, b])
        #expect(plan.isEmpty && sync.cache.reads == 3)
        #expect(sync.cache.cards.allSatisfy { Set($0.object.keys).isSubset(of: Card.fields) })
    }

    @Test func pendingCountIsWhatARunningProfileHasNotLoaded() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B")
        let s1 = Session(), s2 = Session(), mine = Session()
        try home.card(a, s1.card())
        try home.card(a, s2.card())
        try home.card(b, mine.card())
        for s in [s1, s2, mine] { try home.transcript(s) }
        let launchedBefore = Date().addingTimeInterval(-3600)
        try sync(home, [a, b], running: [(b, launchedBefore)])  // B gets s1, s2 while it runs
        #expect(FS.isRegularFile(home.cardFile(b, s1)) && FS.isRegularFile(home.cardFile(b, s2)))

        // Cards created after B launched are not loaded yet; B's own session is.
        #expect(cardSync(home, running: [(b, launchedBefore)]).pendingCount(for: b, among: [a, b]) == 2)
        // B restarted after the copies were made: everything is loaded.
        let relaunched = Date().addingTimeInterval(3600)
        #expect(cardSync(home, running: [(b, relaunched)]).pendingCount(for: b, among: [a, b]) == 0)
        // A new session in A that B has no card for yet.
        let s3 = Session()
        try home.card(a, s3.card())
        try home.transcript(s3)
        #expect(cardSync(home, running: [(b, relaunched)]).pendingCount(for: b, among: [a, b]) == 1)
        // A profile that is not running loads everything at launch.
        #expect(cardSync(home, running: [(b, relaunched)]).pendingCount(for: a, among: [a, b]) == 0)
    }

    @Test func aSessionReplacedInAnOlderFolderIsNotPendingForever() throws {
        let home = try TempHome()
        let a = home.profile("A"), b = home.profile("B"), c = home.profile("C")
        let older = ClaudeProfile(dataDir: b.dataDir, isDefault: false, accountUuid: "55555555-5555-4555-8555-555555555555", orgUuid: org)
        let s = Session(), next = Session()
        try home.card(a, s.card())
        try home.card(b, s.card())
        // In B's earlier account, s was /clear'ed into `next`.
        try home.card(older, next.card(["priorCliSessionIds": [s.cli], "preClearCliSessionId": s.cli]))
        for x in [s, next] { try home.transcript(x) }
        try FileManager.default.createDirectory(at: c.cardsDir!, withIntermediateDirectories: true)
        try sync(home, [a, b, c])
        let relaunched = Date().addingTimeInterval(3600)
        #expect(cardSync(home, running: [(c, relaunched)]).pendingCount(for: c, among: [a, b, c]) == 0)
    }
}
