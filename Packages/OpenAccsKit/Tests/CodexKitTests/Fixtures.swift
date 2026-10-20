import Foundation
import OpenAccsCore
@testable import CodexKit

/// Fake ChatGPT logins. Tokens are unsigned JWTs with only the claims Codex reads.
enum Fake {
    static func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims, options: .sortedKeys)
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(b64).sig"
    }

    static func idToken(user: String, account: String, email: String, plan: String) -> String {
        jwt([
            "email": email, "sub": "auth0|\(user)", "exp": 1_900_000_000,
            "https://api.openai.com/auth": [
                "chatgpt_user_id": user, "user_id": user, "chatgpt_account_id": account, "chatgpt_plan_type": plan,
            ],
        ])
    }

    /// A ChatGPT auth.json as Codex writes it.
    static func auth(
        _ name: String, plan: String = "pro", accessExpires: Date = Date(timeIntervalSince1970: 1_900_000_000),
        refresh: String = "rt.1"
    ) -> Data {
        let root: [String: Any] = [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": [
                "id_token": idToken(user: "user-\(name)", account: "acct-\(name)", email: "\(name)@example.com", plan: plan),
                "access_token": jwt(["exp": accessExpires.timeIntervalSince1970, "who": name]),
                "refresh_token": "\(refresh).\(name)",
                "account_id": "acct-\(name)",
            ],
            "last_refresh": "2026-10-19T18:56:01.123456Z",
            "unknown_future_field": ["kept": true],
        ]
        return try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func info(_ name: String, plan: String = "pro") -> CodexAccountInfo {
        CodexAccountInfo(userId: "user-\(name)", accountId: "acct-\(name)", email: "\(name)@example.com", plan: plan)
    }

    static func tokens(_ data: Data) -> [String: Any] {
        JSON.object(data)?["tokens"] as? [String: Any] ?? [:]
    }
}

/// Records what a switch does to "the Mac", tagging each step with who is signed in at that moment.
final class FakeApp: CodexAppControl, @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    private let authFile: URL
    var running = true
    var quitSucceeds = true
    var onLaunch: @Sendable () -> Void = {}
    var loginWrites: Data?
    var loginHome: URL?
    var loginHomeMode: Int?

    init(authFile: URL) { self.authFile = authFile }

    var log: [String] { lock.withLock { steps } }

    private func record(_ step: String) {
        let who = (try? Data(contentsOf: authFile)).flatMap(CodexAuthFile.identity)?.email ?? "nobody"
        lock.withLock { steps.append("\(step) \(who)") }
    }

    func isRunning() -> Bool { lock.withLock { running } }

    func quit(timeout: Duration) async -> Bool {
        record("quit")
        if quitSucceeds { lock.withLock { running = false } }
        return quitSucceeds
    }

    func launch() async throws {
        record("launch")
        onLaunch()
    }

    func restartDaemon() async throws { record("restartDaemon") }

    func login(codexHome: URL, timeout: Duration) async throws {
        record("login")
        loginHome = codexHome
        loginHomeMode = (try? FileManager.default.attributesOfItem(atPath: codexHome.path))?[.posixPermissions] as? Int
        if let loginWrites { try loginWrites.write(to: codexHome.appending(path: "auth.json")) }
    }
}

/// Counts writes so tests can tell "stored because changed" from "left alone".
final class CountingStore: SecretStore, @unchecked Sendable {
    let inner = MemorySecretStore()
    private let lock = NSLock()
    private var count = 0
    var writes: Int { lock.withLock { count } }

    func read(_ key: String) throws -> Data? { try inner.read(key) }
    func write(_ data: Data, for key: String) throws {
        lock.withLock { count += 1 }
        try inner.write(data, for: key)
    }
    func delete(_ key: String) throws { try inner.delete(key) }
}

/// A throwaway home with a ~/.codex, an in-memory vault, stubbed HTTP and a fake app.
struct Sandbox {
    let home = FileManager.default.temporaryDirectory.appending(path: "openaccs-codex-\(UUID().uuidString)")
    let paths: Paths
    let secrets = CountingStore()
    let http = StubHTTPClient()
    let app: FakeApp
    let accounts: CodexAccounts

    init() throws {
        paths = Paths(home: home)
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        app = FakeApp(authFile: paths.codexAuthFile)
        accounts = CodexAccounts(paths: paths, secrets: secrets, http: http, app: app)
    }

    func setLive(_ data: Data) throws { try data.write(to: paths.codexAuthFile) }
    func live() throws -> Data { try Data(contentsOf: paths.codexAuthFile) }
    func vault(_ name: String) throws -> Data? { try secrets.read("codex:user-\(name):acct-\(name)") }
    func park(_ data: Data, as name: String) throws { try secrets.inner.write(data, for: "codex:user-\(name):acct-\(name)") }

    /// `~/.codex/app-server-daemon/<name>` as the daemon writes it.
    func setDaemonPid(_ name: String, pid: pid_t, startSeconds: Int) throws {
        let file = paths.codexHome.appending(path: "app-server-daemon/\(name)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"pid":\#(pid),"processIdentity":{"startSeconds":\#(startSeconds)}}"#.utf8).write(to: file)
    }
}
