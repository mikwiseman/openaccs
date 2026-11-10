import Foundation
import Testing
@testable import OpenAccsCore

@Suite struct ClaudeMembershipPersistenceTests {
    @Test func oldProfileJSONStillDecodes() throws {
        let info = try JSONDecoder().decode(ClaudeAccountInfo.self, from: Data(#"{"accountUuid":"account-a","dataDir":"/tmp/claude"}"#.utf8))
        #expect(info.organizationUuid == nil)
        #expect(info.organizationName == nil)
        #expect(info.email == nil)
        #expect(info.plan == nil)
        #expect(info.accountUuid == "account-a")
    }

    @Test func twoMembershipsRoundTripWithOneDataDirectory() throws {
        let team = ClaudeAccountInfo(dataDir: "/tmp/claude", accountUuid: "account-a", organizationUuid: "team-a", organizationName: "WaiWai Team", email: "me@example.com", plan: "Team")
        let personal = ClaudeAccountInfo(dataDir: "/tmp/claude", accountUuid: "account-a", organizationUuid: "personal-a", organizationName: "Personal Max", email: "me@example.com", plan: "Max")
        let encoded = try JSONEncoder().encode([team, personal])
        #expect(try JSONDecoder().decode([ClaudeAccountInfo].self, from: encoded) == [team, personal])
        #expect(team != personal)
    }
}
