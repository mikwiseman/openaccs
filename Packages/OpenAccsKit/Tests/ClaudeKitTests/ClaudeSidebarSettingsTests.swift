import Foundation
import OpenAccsCore
import Testing
@testable import ClaudeKit

private let sidebarKey = "ccd/dframe-store"
private let sidebarAccount = ClaudeAccountKey(account: "account-a", org: "org-a")!

private func sidebarEnvelope(groupBy: String = "folder", sortBy: String = "title", ascending: Bool = true) -> [String: Any] {
    ["version": 3, "updatedAt": 1, "futureEnvelopeField": "keep", "state": [
        "sidebarSections": [
            ["id": "pinned", "kind": "pinned", "collapsed": true, "order": 0],
            ["id": "routines", "kind": "routines", "shown": false, "order": 1],
            ["id": "sessions", "kind": "sessions", "groupBy": groupBy, "sortBy": sortBy,
             "ascending": ascending, "order": 2, "show": ["metadata": true]],
            ["id": "my-section", "kind": "manual", "name": "Work", "order": 3],
        ],
        "pinnedOrder": ["code:local_one", "code:local_two"],
        "customGroups": ["groups": [["id": "group-a", "name": "My group"]], "assignments": ["chat": "group-a"]],
        "futureStateField": ["value": 42],
    ]]
}

private func sidebarResponse(_ envelope: [String: Any]?, user: String = "account-a", checksum: String = "v1") throws -> Data {
    var entries = ["other-setting": "must not be changed"]
    if let envelope {
        entries[sidebarKey] = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
    }
    return try JSONSerialization.data(withJSONObject: ["userId": user, "checksum": checksum, "content": ["entries": entries]])
}

private func sidebarBody(_ request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    let object = try #require(JSON.object(body))
    let entries = try #require(object["entries"] as? [String: String])
    #expect(Set(entries.keys) == [sidebarKey])
    let text = try #require(entries[sidebarKey])
    return try #require(JSON.object(Data(text.utf8)))
}

/// The server commits a conditional write, but its response never reaches the client.
private actor SidebarWriteTimeoutHTTPClient: HTTPClient {
    private var body: Data
    private var checksum = "v1"
    private var requests: [URLRequest] = []

    init() throws { body = try sidebarResponse(sidebarEnvelope()) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        if request.httpMethod == "PUT" {
            guard request.value(forHTTPHeaderField: "If-Match") == checksum else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 412, httpVersion: nil, headerFields: nil)!)
            }
            checksum = "v2"
            body = try sidebarResponse(sidebarBody(request), checksum: checksum)
            throw UsageError.network("The request timed out.")
        }
        #expect(request.httpMethod == "GET")
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func snapshot() -> (requests: [URLRequest], body: Data) { (requests, body) }
}

@Suite struct ClaudeSidebarSettingsTests {
    @Test func changesOnlyChronologicalPreferencesAndUsesTheReadChecksum() async throws {
        let http = StubHTTPClient()
        let before = sidebarEnvelope()
        http.on("https://claude.ai/api/claude_code/organizations/org-a/user_settings",
                .init(body: try sidebarResponse(before, user: "ACCOUNT-A")), .init(json: "{}"),
                .init(body: try sidebarResponse(sidebarEnvelope(groupBy: "date", sortBy: "recency", ascending: false))))
        let result = try await ClaudeSidebarSettings(http: http).apply(session: "sk-ant-fixture", account: sidebarAccount,
                                                                     now: Date(timeIntervalSince1970: 123))
        #expect(result == .updated)
        #expect(http.requests.count == 3)
        let write = try #require(http.requests.first { $0.httpMethod == "PUT" })
        #expect(write.httpMethod == "PUT")
        #expect(write.value(forHTTPHeaderField: "If-Match") == "v1")
        #expect(write.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(http.requests.allSatisfy { $0.url?.host == "claude.ai" })
        let after = try sidebarBody(write)
        var expected = before
        expected["updatedAt"] = 123_000
        var state = try #require(expected["state"] as? [String: Any])
        var sections = try #require(state["sidebarSections"] as? [[String: Any]])
        sections[2]["groupBy"] = "date"
        sections[2]["sortBy"] = "recency"
        sections[2]["ascending"] = false
        state["sidebarSections"] = sections
        expected["state"] = state
        #expect(after as NSDictionary == expected as NSDictionary)
    }

    @Test func anAlreadyChronologicalSidebarIsNotWritten() async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai", .init(body: try sidebarResponse(sidebarEnvelope(groupBy: "date", sortBy: "recency", ascending: false))))
        let result = try await ClaudeSidebarSettings(http: http).apply(session: "sk-ant-fixture", account: sidebarAccount)
        #expect(result == .unchanged)
        #expect(http.requests.count == 1)
        #expect(http.requests.first?.httpMethod == "GET")
    }

    @Test func aTimedOutCommittedWriteIsReadBackWithoutAnotherWrite() async throws {
        let http = try SidebarWriteTimeoutHTTPClient()
        let settings = ClaudeSidebarSettings(http: http)
        await #expect(throws: UsageError.network("The request timed out.")) {
            try await settings.apply(session: "sk-ant-fixture", account: sidebarAccount,
                                     now: Date(timeIntervalSince1970: 123))
        }
        let interrupted = await http.snapshot()
        #expect(interrupted.requests.map(\.httpMethod) == ["GET", "PUT"])

        #expect(try await settings.apply(session: "sk-ant-fixture", account: sidebarAccount,
                                         now: Date(timeIntervalSince1970: 456)) == .unchanged)
        let recovered = await http.snapshot()
        #expect(recovered.requests.map(\.httpMethod) == ["GET", "PUT", "GET"])
        #expect(recovered.body == interrupted.body)
        let object = try #require(JSON.object(recovered.body))
        let content = try #require(object["content"] as? [String: Any])
        let entries = try #require(content["entries"] as? [String: String])
        #expect(entries["other-setting"] == "must not be changed")
        let saved = try #require(entries[sidebarKey])
        let envelope = try #require(JSON.object(Data(saved.utf8)))
        var expected = sidebarEnvelope(groupBy: "date", sortBy: "recency", ascending: false)
        expected["updatedAt"] = 123_000
        #expect(envelope as NSDictionary == expected as NSDictionary)
    }

    @Test(arguments: ["ABCDEF0123456789ABCD0123456789AB", "abcdef01-2345-6789-abcd-0123456789ab"])
    func nativeAccountIdsMatchWithOrWithoutUUIDSeparators(owner: String) async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai", .init(body: try sidebarResponse(sidebarEnvelope(groupBy: "date", sortBy: "recency", ascending: false), user: owner)))
        let account = try #require(ClaudeAccountKey(account: "abcdef01-2345-6789-abcd-0123456789ab", org: "org-a"))
        #expect(try await ClaudeSidebarSettings(http: http).apply(session: "sk-ant-fixture", account: account) == .unchanged)
        #expect(http.requests.count == 1)
    }

    @Test func inaccessibleMembershipHasASidebarSpecificError() async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai", .init(status: 403, json: "{}"))
        await #expect(throws: UsageError.unexpected("Claude's sidebar membership is unavailable")) {
            try await ClaudeSidebarSettings(http: http).apply(session: "sk-ant-fixture", account: sidebarAccount)
        }
        #expect(http.requests.count == 1)
    }

    @Test func anotherAccountNeverReceivesTheWrite() async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai", .init(body: try sidebarResponse(sidebarEnvelope(), user: "account-b")))
        await #expect(throws: UsageError.unexpected("Claude is signed in to another account")) {
            try await ClaudeSidebarSettings(http: http).apply(session: "sk-ant-fixture", account: sidebarAccount)
        }
        #expect(http.requests.count == 1)
    }

    @Test func conflictsRefetchAndKeepTheConcurrentChange() async throws {
        let http = StubHTTPClient()
        var latest = sidebarEnvelope()
        var state = try #require(latest["state"] as? [String: Any])
        state["pinnedOrder"] = ["code:local_one", "code:local_two", "code:concurrently-pinned"]
        state["newRemoteOnlyField"] = "keep this too"
        latest["state"] = state
        http.on("https://claude.ai",
                .init(body: try sidebarResponse(sidebarEnvelope())), .init(status: 412, json: "{}"),
                .init(body: try sidebarResponse(latest, checksum: "v2")), .init(json: "{}"),
                .init(body: try sidebarResponse(sidebarEnvelope(groupBy: "date", sortBy: "recency", ascending: false))))
        #expect(try await ClaudeSidebarSettings(http: http).apply(session: "sk-ant-fixture", account: sidebarAccount) == .updated)
        #expect(http.requests.map(\.httpMethod) == ["GET", "PUT", "GET", "PUT", "GET"])
        let write = try #require(http.requests.last { $0.httpMethod == "PUT" })
        #expect(write.value(forHTTPHeaderField: "If-Match") == "v2")
        let actual = try sidebarBody(write)
        let actualState = try #require(actual["state"] as? [String: Any])
        #expect(actualState["pinnedOrder"] as? [String] == state["pinnedOrder"] as? [String])
        #expect(actualState["newRemoteOnlyField"] as? String == "keep this too")
    }

    @Test func persistentConflictsStopAfterThreeWrites() async throws {
        let http = StubHTTPClient()
        let response = try sidebarResponse(sidebarEnvelope())
        http.on("https://claude.ai", .init(body: response), .init(status: 409, json: "{}"),
                .init(body: response), .init(status: 412, json: "{}"), .init(body: response), .init(status: 409, json: "{}"))
        await #expect(throws: UsageError.unexpected("Claude's sidebar changed during the update. Try again.")) {
            try await ClaudeSidebarSettings(http: http).apply(session: "sk-ant-fixture", account: sidebarAccount)
        }
        #expect(http.requests.count == 6)
    }

    @Test func firstAuthorizationWithoutASidebarWaitsForClaudeToCreateIt() async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai", .init(body: try sidebarResponse(nil)))
        #expect(try await ClaudeSidebarSettings(http: http).apply(session: "sk-ant-fixture", account: sidebarAccount) == .awaitingSidebar)
        #expect(http.requests.count == 1)
    }

    @Test func aSuccessfulResponseStillRequiresReadback() async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai", .init(body: try sidebarResponse(sidebarEnvelope())), .init(json: "{}"),
                .init(body: try sidebarResponse(sidebarEnvelope())))
        await #expect(throws: UsageError.unexpected("Claude's sidebar update was not confirmed")) {
            try await ClaudeSidebarSettings(http: http).apply(session: "sk-ant-fixture", account: sidebarAccount)
        }
        #expect(http.requests.map(\.httpMethod) == ["GET", "PUT", "GET"])
    }

    @Test func unknownOrMalformedStateIsNeverReset() async throws {
        for envelope: [String: Any] in [[:], ["state": ["sidebarSections": "unexpected"]],
                                        ["state": ["sidebarSections": [["kind": "manual", "id": "sessions"]]]]] {
            let http = StubHTTPClient()
            http.on("https://claude.ai", .init(body: try sidebarResponse(envelope)))
            await #expect(throws: UsageError.unexpected("Claude's sidebar format is not supported")) {
                try await ClaudeSidebarSettings(http: http).apply(session: "sk-ant-fixture", account: sidebarAccount)
            }
            #expect(http.requests.count == 1)
        }
    }

    @Test func missingChecksumNeverMakesAnUnconditionalWrite() async throws {
        let http = StubHTTPClient()
        http.on("https://claude.ai", .init(body: try sidebarResponse(sidebarEnvelope(), checksum: "")))
        await #expect(throws: UsageError.unexpected("Claude's sidebar response has no checksum")) {
            try await ClaudeSidebarSettings(http: http).apply(session: "sk-ant-fixture", account: sidebarAccount)
        }
        #expect(http.requests.count == 1)
    }
}
