import Foundation
import OpenAccsCore
import Testing
@testable import ClaudeKit

@Suite struct ClaudeMembershipTests {
    private let dir = FileManager.default.temporaryDirectory.appending(path: "openaccs-membership-\(UUID())")

    @Test func confirmedDesktopIdentityIsPersistedWithoutFollowingLaterSelection() throws {
        var info = ClaudeAccountInfo(dataDir: dir.path)
        let personal = ClaudeProfile(dataDir: URL(filePath: dir.path, directoryHint: .isDirectory), isDefault: false, accountUuid: "account-a", orgUuid: "personal-a", isConfirmed: true)
        personal.recordIdentity(in: &info)
        #expect(info.accountUuid == "account-a")
        #expect(info.organizationUuid == "personal-a")
        let store = AccountStore(file: dir.appending(path: "accounts.json"))
        try store.save([Account(provider: .claude, label: "Personal", claude: info)])
        var saved = try #require(store.load().first?.claude)
        let team = ClaudeProfile(dataDir: URL(filePath: dir.path, directoryHint: .isDirectory), isDefault: false, accountUuid: "account-a", orgUuid: "team-a", isConfirmed: true)
        team.recordIdentity(in: &saved)
        #expect(saved == info)
    }

    @Test func ambiguousProfileDoesNotPinAGuessedMembership() throws {
        var info = ClaudeAccountInfo(dataDir: dir.path, accountUuid: "account-a")
        var guessed = ClaudeProfile(dataDir: URL(filePath: dir.path, directoryHint: .isDirectory), isDefault: false, accountUuid: "account-a", orgUuid: "personal-a")
        guessed.orgIsGuess = true
        guessed.recordIdentity(in: &info)
        #expect(info.organizationUuid == nil)
        let original = Account(provider: .claude, label: "Login", claude: info)
        var accounts = [original]
        let profiles = ClaudeProfiles(paths: Paths(home: dir))
        #expect(throws: (any Error).self) {
            try profiles.mergeMemberships(memberships(), source: info, profile: guessed, accounts: &accounts, colorCount: 5)
        }
        #expect(accounts.first { $0.id == original.id } == original)
        #expect(accounts.count == 1)
        guessed.isConfirmed = true
        guessed.orgIsGuess = false
        try profiles.mergeMemberships(memberships(), source: info, profile: guessed, accounts: &accounts, colorCount: 5)
        let once = accounts
        try profiles.mergeMemberships(memberships(), source: info, profile: guessed, accounts: &accounts, colorCount: 5)
        #expect(accounts == once)
        #expect(accounts.count == 2)
        #expect(accounts.first { $0.id == original.id }?.claude?.organizationUuid == "personal-a")
    }

    @Test func repeatedDiscoveryKeepsRowsAndIsolatesNativeConnections() throws {
        var source = ClaudeAccountInfo(dataDir: dir.path, legacyConfigDir: "/tmp/legacy", cliConfigDir: "/tmp/personal-cli", accountUuid: "account-a")
        source.migratedFrom = "/tmp/old"
        source.importedFingerprint = "keep-fingerprint"
        let original = Account(provider: .claude, label: "My Personal", color: 3, claude: source)
        var accounts = [original]
        let profile = ClaudeProfile(dataDir: URL(filePath: dir.path, directoryHint: .isDirectory), isDefault: false, accountUuid: "account-a", orgUuid: "personal-a", isConfirmed: true)
        let profiles = ClaudeProfiles(paths: Paths(home: dir))
        let found = try memberships()
        try profiles.mergeMemberships(found, source: source, profile: profile, accounts: &accounts, colorCount: 5)
        let once = accounts
        try profiles.mergeMemberships(found, source: source, profile: profile, accounts: &accounts, colorCount: 5)
        #expect(accounts == once)
        #expect(accounts.count == 2)
        let personal = try #require(accounts.first { $0.id == original.id })
        #expect(personal.claude?.organizationUuid == "personal-a")
        #expect(personal.label == "My Personal")
        #expect(personal.color == 3)
        #expect(personal.claude?.cliConfigDir == "/tmp/personal-cli")
        #expect(personal.claude?.migratedFrom == "/tmp/old")
        #expect(personal.claude?.importedFingerprint == "keep-fingerprint")
        let team = try #require(accounts.first { $0.claude?.organizationUuid == "team-a" })
        #expect(team.claude?.cliConfigDir == nil)
        #expect(team.claude?.email == personal.claude?.email)
        #expect(personal.claude?.plan == "Max")
        #expect(team.claude?.plan == "Team")
    }

    @Test func revokedSelectedMembershipDoesNotLeaveAnUnpinnedDuplicate() throws {
        let info = ClaudeAccountInfo(dataDir: dir.path, accountUuid: "account-a")
        let original = Account(provider: .claude, label: "Personal", claude: info)
        var accounts = [original]
        let profile = ClaudeProfile(dataDir: dir, isDefault: false, accountUuid: "account-a", orgUuid: "personal-a", isConfirmed: true)
        let available = try memberships().filter { $0.organizationUuid == "team-a" }
        #expect(throws: UsageError.unexpected("Select a membership in Claude, then discover again")) {
            try ClaudeProfiles(paths: Paths(home: dir)).mergeMemberships(available, source: info, profile: profile,
                                                                       accounts: &accounts, colorCount: 5)
        }
        #expect(accounts == [original])
    }

    @Test func discoveryCannotReplaceAnExistingUnpinnedLogin() throws {
        let info = ClaudeAccountInfo(dataDir: dir.path, accountUuid: "account-b")
        let original = Account(provider: .claude, label: "Other login", claude: info)
        var accounts = [original]
        let profile = ClaudeProfile(dataDir: dir, isDefault: false, accountUuid: "account-a", orgUuid: "personal-a", isConfirmed: true)
        #expect(throws: UsageError.unexpected("Claude is signed in to another account")) {
            try ClaudeProfiles(paths: Paths(home: dir)).mergeMemberships(memberships(), source: info, profile: profile,
                                                                       accounts: &accounts, colorCount: 5)
        }
        #expect(accounts == [original])
    }

    @Test func confirmedObservationDoesNotDuplicateAnExistingCanonicalMembership() {
        var info = ClaudeAccountInfo(accountUuid: "account-a")
        let profile = ClaudeProfile(dataDir: dir, isDefault: false, accountUuid: "account-a", orgUuid: "personal-a", isConfirmed: true)
        profile.recordIdentity(in: &info, knownMemberships: [ClaudeAccountKey(account: "account-a", org: "personal-a")!])
        #expect(info.organizationUuid == nil)
    }

    @Test func anotherLoginCannotReplaceStoredIdentity() {
        var info = ClaudeAccountInfo(accountUuid: "account-b")
        let observed = ClaudeProfile(dataDir: URL(filePath: dir.path, directoryHint: .isDirectory), isDefault: false, accountUuid: "account-a", orgUuid: "personal-a", isConfirmed: true)
        observed.recordIdentity(in: &info)
        #expect(info.accountUuid == "account-b")
        #expect(info.organizationUuid == nil)
    }

    @Test func revokedMembershipNeverFetchesOrReportsItsOldQuota() async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai/api/account", .init(json: #"{"uuid":"account-a","memberships":[{"organization":{"uuid":"personal-a"}}]}"#))
        http.on("https://claude.ai/api/organizations/team-a/usage", .init(json: #"{"five_hour":{"utilization":10}}"#))
        await #expect(throws: UsageError.membershipUnavailable) {
            try await ClaudeDesktopUsage(http: http).fetch(session: "sk-ant-test", account: ClaudeAccountKey(account: "account-a", org: "team-a")!)
        }
        #expect(http.requests.count == 1)
    }

    private func memberships() throws -> [ClaudeMembership] {
        try ClaudeMembership.parse([
            "uuid": "account-a", "email_address": "me@example.com",
            "memberships": [
                ["organization": ["uuid": "personal-a", "name": "Personal", "organization_type": "claude_max"]],
                ["organization": ["uuid": "team-a", "name": "WaiWai", "organization_type": "claude_team"]],
            ],
        ], account: "account-a")
    }

    @Test func oneLoginHasTwoDistinctMemberships() async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai/api/account", .init(json: #"{"uuid":"account-a","email_address":"me@example.com","memberships":[{"organization":{"uuid":"team-a","name":"WaiWai Team","organization_type":"claude_team"}},{"organization":{"uuid":"personal-a","name":"Personal","plan_display_name":"Max"}},{"organization":{"uuid":"TEAM-A","name":"WaiWai Team"}}]}"#))
        let memberships = try await ClaudeDesktopUsage(http: http).fetchMemberships(session: "sk-ant-test", account: "ACCOUNT-A")
        #expect(memberships.count == 2)
        #expect(memberships.map(\.key.description) == ["account-a/team-a", "account-a/personal-a"])
        #expect(memberships.map(\.organizationName) == ["WaiWai Team", "Personal"])
        #expect(memberships.map(\.plan) == ["Team", "Max"])
        #expect(memberships.allSatisfy { $0.email == "me@example.com" })
        #expect(http.requests.count == 1)
    }

    @Test func rejectsChangedLoginBeforeImportingItsMemberships() async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai/api/account", .init(json: #"{"uuid":"account-b","memberships":[{"organization":{"uuid":"team-a","name":"Team"}}]}"#))
        await #expect(throws: UsageError.unexpected("Claude is signed in to another account")) {
            try await ClaudeDesktopUsage(http: http).fetchMemberships(session: "sk-ant-test", account: "account-a")
        }
    }

    @Test func oneLoginReadsDifferentLimitsForEachMembership() async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai/api/account", .init(json: #"{"uuid":"account-a","memberships":[{"organization":{"uuid":"team-a","organization_type":"claude_team"}},{"organization":{"uuid":"personal-a","organization_type":"claude_max"}}]}"#))
        http.on("https://claude.ai/api/organizations/team-a/usage", .init(json: #"{"five_hour":{"utilization":10}}"#))
        http.on("https://claude.ai/api/organizations/personal-a/usage", .init(json: #"{"five_hour":{"utilization":100}}"#))
        let reader = ClaudeDesktopUsage(http: http)
        let team = try await reader.fetch(session: "sk-ant-test", account: ClaudeAccountKey(account: "account-a", org: "team-a")!)
        let personal = try await reader.fetch(session: "sk-ant-test", account: ClaudeAccountKey(account: "account-a", org: "personal-a")!)
        #expect(team.window(.fiveHour)?.usedPercent == 10)
        #expect(personal.window(.fiveHour)?.usedPercent == 100)
        #expect(team.plan == "Team")
        #expect(personal.plan == "Max")
        #expect(http.requests.compactMap { $0.url?.path } == ["/api/account", "/api/organizations/team-a/usage", "/api/account", "/api/organizations/personal-a/usage"])
    }

    @Test func rejectsMalformedMembershipIdentity() async throws {
        for body in [
            #"{"uuid":"account-a"}"#,
            #"{"uuid":"account-a","memberships":[{"organization":{"name":"Team"}}]}"#,
            #"{"uuid":"account-a","memberships":[{"organization":{"uuid":"../other","name":"Team"}}]}"#,
        ] {
            let http = StubHTTPClient()
            http.on("https://claude.ai/api/account", .init(json: body))
            await #expect(throws: (any Error).self) {
                try await ClaudeDesktopUsage(http: http).fetchMemberships(session: "sk-ant-test", account: "account-a")
            }
        }
    }

    @Test func quotasStayPinnedWhileTheWindowSelectsAnotherMembership() {
        let profile = ClaudeProfile(dataDir: URL(filePath: "/tmp/claude-membership"), isDefault: false,
                                    accountUuid: "account-a", orgUuid: "personal-a", isConfirmed: true)
        let team = ClaudeAccountInfo(accountUuid: "ACCOUNT-A", organizationUuid: "TEAM-A")
        #expect(profile.limitsAccount(addedAs: team)?.description == "account-a/team-a")
        #expect(!profile.requestedMembershipIsSelected(team))
        let personal = ClaudeAccountInfo(accountUuid: "account-a", organizationUuid: "personal-a")
        #expect(profile.requestedMembershipIsSelected(personal))
        #expect(profile.orgUuid == "personal-a")
    }

    @Test func wrongOrUnknownObservedAccountCannotResolveAPinnedMembership() {
        let team = ClaudeAccountInfo(accountUuid: "account-a", organizationUuid: "team-a")
        for observed in ["account-b", nil] as [String?] {
            let profile = ClaudeProfile(dataDir: URL(filePath: "/tmp/claude-membership"), isDefault: false,
                                        accountUuid: observed, orgUuid: "team-a", isConfirmed: true)
            #expect(profile.limitsAccount(addedAs: team) == nil)
            #expect(!profile.requestedMembershipIsSelected(team))
        }
    }

    @Test func unconfirmedFolderIsNotSelectionProof() {
        let profile = ClaudeProfile(dataDir: URL(filePath: "/tmp/claude-membership"), isDefault: false,
                                    accountUuid: "account-a", orgUuid: "team-a")
        #expect(!profile.requestedMembershipIsSelected(ClaudeAccountInfo(accountUuid: "account-a", organizationUuid: "team-a")))
    }

    @Test func unpinnedProfilesKeepTheirExistingLimitsResolution() {
        let profile = ClaudeProfile(dataDir: URL(filePath: "/tmp/claude-membership"), isDefault: false,
                                    accountUuid: "account-a", orgUuid: "team-a", isConfirmed: true)
        #expect(profile.limitsAccount(addedAs: ClaudeAccountInfo(accountUuid: "account-a")) ==
                profile.limitsAccount(addedAs: "account-a"))
        #expect(profile.limitsAccount(addedAs: ClaudeAccountInfo(accountUuid: "different-login")) == nil)
    }
}
