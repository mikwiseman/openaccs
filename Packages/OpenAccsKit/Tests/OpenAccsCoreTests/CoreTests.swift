import Foundation
import Testing
@testable import OpenAccsCore

@Suite struct CoreTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "openaccs-core-\(UUID().uuidString)")

    @Test func atomicWriteReplacesAndSetsMode() throws {
        let file = dir.appending(path: "a/b.json")
        try AtomicFile.write(Data("one".utf8), to: file)
        try AtomicFile.write(Data("two".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(leftovers == ["b.json"])
    }

    @Test func createExclusivelyNeverReplaces() throws {
        let file = dir.appending(path: "card.json")
        #expect(try AtomicFile.createExclusively(Data("first".utf8), at: file))
        #expect(try AtomicFile.createExclusively(Data("second".utf8), at: file) == false)
        #expect(try String(contentsOf: file, encoding: .utf8) == "first")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["card.json"])
    }

    @Test func accountsRoundTrip() throws {
        let store = AccountStore(file: dir.appending(path: "accounts.json"))
        #expect(try store.load().isEmpty)
        let a = Account(provider: .claude, label: "me@example.com", createdAt: Date(timeIntervalSince1970: 1_790_000_000.25), claude: ClaudeAccountInfo(dataDir: nil))
        try store.save([a])
        #expect(try store.load() == [a])
    }

    @Test func jwtClaimsAndDates() {
        // {"exp":1792874740,"email":"a@b.c"}
        let token = "x." + Data(#"{"exp":1792874740,"email":"a@b.c"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "") + ".y"
        #expect(JWT.claims(token)?["email"] as? String == "a@b.c")
        #expect(JWT.expiry(token) == Date(timeIntervalSince1970: 1792874740))
        #expect(JSON.date("2026-10-20T08:00:00Z") == JSON.date("2026-10-20T08:00:00.000Z"))
        #expect(JSON.date(1792684605507.0) == Date(timeIntervalSince1970: 1792684605.507))
    }

    @Test func processRunnerAndArgs() async throws {
        let r = try await ProcessRunner.run(URL(filePath: "/bin/echo"), ["hi"])
        #expect(r.status == 0 && r.stdoutString == "hi\n")
        let me = ProcessInfo.processInfo.processIdentifier
        #expect(ProcessList.arguments(of: me)?.isEmpty == false)
        #expect(ProcessList.all().contains { $0.pid == me })
    }

    @Test func lineProcessRoundTrip() async throws {
        let p = try LineProcess(URL(filePath: "/bin/cat"), [], environment: ProcessRunner.cleanEnvironment())
        p.send(json: ["id": 7])
        let got = await p.firstJSON(timeout: .seconds(5)) { $0["id"] as? Int == 7 }
        #expect(got != nil)
        p.terminate()
    }

    @Test func memorySecrets() throws {
        let s = MemorySecretStore()
        try s.write(Data("k".utf8), for: "a")
        #expect(try s.read("a") == Data("k".utf8))
        try s.delete("a")
        #expect(try s.read("a") == nil)
    }
}

@Suite struct CoreSafetyTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "openaccs-core2-\(UUID().uuidString)")

    @Test func unreadableAccountsFileThrowsInsteadOfLookingEmpty() throws {
        let file = dir.appending(path: "accounts.json")
        try AtomicFile.write(Data(#"[{"id":"\#(UUID().uuidString)","provider":"gemini","label":"x","color":0,"createdAt":"2026-10-20T08:00:00.000Z"}]"#.utf8), to: file)
        #expect(throws: (any Error).self) { try AccountStore(file: file).load() }
        #expect(try AccountStore(file: dir.appending(path: "missing.json")).load().isEmpty)
    }

    @Test func cancellingARunEndsTheChild() async throws {
        let task = Task { try await ProcessRunner.run(URL(filePath: "/bin/sleep"), ["20"], timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        task.cancel()
        _ = await task.result
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func accountVariablesAreRecognized() {
        #expect(ProcessRunner.isAccountVariable("CLAUDE_CONFIG_DIR"))
        #expect(ProcessRunner.isAccountVariable("ANTHROPIC_BASE_URL"))
        #expect(ProcessRunner.isAccountVariable("CODEX_HOME"))
        #expect(!ProcessRunner.isAccountVariable("PATH"))
    }
}
