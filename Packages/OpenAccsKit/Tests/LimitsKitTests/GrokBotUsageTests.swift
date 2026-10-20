import Foundation
import OpenAccsCore
import Testing
@testable import LimitsKit

@Suite struct GrokBotUsageTests {
    /// RFC 4648 base32, lowercase, no padding: how Grok Bot names its blobs.
    static func base32(_ text: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var out = "", buffer = 0, bits = 0
        for byte in Data(text.utf8) {
            buffer = (buffer << 8 | Int(byte)) & 0xFFFF
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 31])
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    func persistenceDir(_ home: URL) throws -> URL {
        let dir = Paths(home: home).grokBotPersistenceDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func writeBlob(_ key: String, _ json: String, in dir: URL) throws {
        try Data(json.utf8).write(to: dir.appending(path: Self.base32(key) + ".blob"))
    }

    @Test func base32MatchesRealFileNamesAndRFCVectors() {
        // The first 24 characters of a real Grok Bot blob name.
        #expect(Self.base32("sand.client.sli") == "onqw4zbomnwgszlooqxhg3dj")
        #expect(Base32.decode("onqw4zbomnwgszlooqxhg3dj").flatMap { String(data: $0, encoding: .utf8) } == "sand.client.sli")
        #expect(Self.base32("foobar") == "mzxw6ytboi")
        #expect(Base32.decode("MZXW6YTBOI======") == Data("foobar".utf8))
        #expect(Base32.decode("mzxw6ytboi") == Data("foobar".utf8))
        #expect(Base32.decode("not base32!") == nil)
    }

    @Test func readsWeeklyUsageForEachAccount() throws {
        let home = try makeTempDir("grokbot")
        let dir = try persistenceDir(home)
        let reset: Int64 = 1_792_684_605_507, readAt: Int64 = 1_792_437_092_193
        try writeBlob("sand.client.slice.account.google-oauth2%7Cuser_abc.weekly-usage.cache", """
        {"schemaVersion":2,"value":{"kind":"present","selectedTeamId":null,"reading":{"usage":{"percentUsed":47.28634197660746,
         "nextResetMs":\(reset),"isSandTrial":false,"hasNonZeroIncludedLimit":true,"isTeamSeat":false,"onDemand":null,
         "grokPlanLabel":"Grok Bot Plan"},"readAtMs":\(readAt)},"expiresAtMs":1792523492193}}
        """, in: dir)
        try writeBlob("sand.client.slice.account.auth0%7Czed.weekly-usage.cache",
                      #"{"schemaVersion":2,"value":{"kind":"present","reading":{"usage":{"percentUsed":100},"readAtMs":1792437092193}}}"#, in: dir)
        // Other slices of the same account, other keys, and junk are ignored.
        try writeBlob("sand.client.slice.account.google-oauth2%7Cuser_abc.roster.last-roster", "{}", in: dir)
        try writeBlob("sand.client.slice.ui-layout", "{}", in: dir)
        try Data().write(to: dir.appending(path: "LOCK"))

        let bot = GrokBotUsage(paths: Paths(home: home))
        #expect(bot.accounts() == ["auth0|zed", "google-oauth2|user_abc"])

        let s = try #require(bot.read(account: "google-oauth2|user_abc"))
        #expect(s.plan == "Grok Bot Plan")
        #expect(s.source == "Grok Bot")
        #expect(s.asOf == Date(timeIntervalSince1970: Double(readAt) / 1000))
        #expect(s.windows.count == 1)
        #expect(abs((s.window(.weekly)?.usedPercent ?? 0) - 47.28634197660746) < 1e-9)
        #expect(s.window(.weekly)?.resetsAt == Date(timeIntervalSince1970: Double(reset) / 1000))

        let zed = try #require(bot.read(account: "auth0|zed"))
        #expect(zed.plan == nil && zed.window(.weekly)?.usedPercent == 100 && zed.window(.weekly)?.resetsAt == nil)
    }

    @Test func missingOrGarbledIsNil() throws {
        let home = try makeTempDir("grokbot-bad")
        #expect(GrokBotUsage(paths: Paths(home: home)).accounts().isEmpty)   // no folder at all
        let dir = try persistenceDir(home)
        try writeBlob("sand.client.slice.account.a.weekly-usage.cache", "not json", in: dir)
        try writeBlob("sand.client.slice.account.b.weekly-usage.cache", #"{"schemaVersion":2,"value":{"kind":"absent"}}"#, in: dir)
        try writeBlob("sand.client.slice.account.c.weekly-usage.cache",
                      #"{"schemaVersion":2,"value":{"kind":"present","reading":{"usage":{"grokPlanLabel":"X"},"readAtMs":1}}}"#, in: dir)
        let bot = GrokBotUsage(paths: Paths(home: home))
        #expect(bot.accounts() == ["a", "b", "c"])
        #expect(bot.read(account: "a") == nil)
        #expect(bot.read(account: "b") == nil)
        #expect(bot.read(account: "c") == nil)
        #expect(bot.read(account: "nobody") == nil)
    }
}
