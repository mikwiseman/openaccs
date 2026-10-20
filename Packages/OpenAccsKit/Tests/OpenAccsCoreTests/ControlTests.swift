import Darwin
import Foundation
import Testing
@testable import OpenAccsCore

// MARK: Socket server and client

@Suite(.serialized) struct ControlSocketTests {
    /// Deliberately long (over sun_path's 104 bytes): a long home folder must still work.
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "openaccs-control-\(UUID().uuidString)/a-folder-name-long-enough-to-push-the-socket-path-past-sun-path")
    var socket: URL { dir.appending(path: "control.sock") }

    static func accounts() -> [ControlAccount] {
        [ControlAccount(id: UUID(), provider: .claude, label: "me@example.com", state: .open,
                        usage: UsageSnapshot(windows: [UsageWindow(kind: .fiveHour, usedPercent: 38)], asOf: Date(timeIntervalSince1970: 1_792_000_000), source: "Claude app"))]
    }

    @Test func roundTripAndPermissions() throws {
        #expect(socket.path.utf8.count > 104)
        let accounts = Self.accounts()
        let server = ControlServer(socket: socket) { request in
            ControlResponse(error: request.command == .status ? nil : "only status", accounts: accounts, notice: request.name)
        }
        try server.start()
        defer { server.stop() }

        let reply = try ControlClient.send(ControlRequest(.status, name: "hello"), to: socket)
        #expect(reply == ControlResponse(accounts: accounts, notice: "hello"))
        #expect(try ControlClient.send(ControlRequest(.refresh), to: socket).error == "only status")
        #expect(ControlClient.isAnswering(socket))

        let fm = FileManager.default
        #expect(try fm.attributesOfItem(atPath: socket.path)[.posixPermissions] as? Int == 0o600)
        #expect(try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int == 0o700)
        #expect(try fm.attributesOfItem(atPath: socket.path)[.type] as? FileAttributeType == .typeSocket)
    }

    @Test func unreachableWithoutServer() {
        #expect(throws: ControlError.unreachable) { try ControlClient.send(ControlRequest(.status), to: socket) }
        #expect(!ControlClient.isAnswering(socket))
    }

    @Test func refusesWhenAnotherServerAnswers() throws {
        let first = ControlServer(socket: socket) { _ in ControlResponse(notice: "first") }
        try first.start()
        defer { first.stop() }
        let second = ControlServer(socket: socket) { _ in ControlResponse(notice: "second") }
        #expect(throws: ControlError.alreadyRunning) { try second.start() }
        #expect(try ControlClient.send(ControlRequest(.status), to: socket).notice == "first")
    }

    @Test func replacesAStaleSocket() throws {
        // A socket file nobody listens on, as left by an app that crashed.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(try UnixSocket.withAddress(socket.path) { bind(fd, $0, $1) } == 0)
        close(fd)
        #expect(!ControlClient.isAnswering(socket))

        let server = ControlServer(socket: socket) { _ in ControlResponse(notice: "fresh") }
        try server.start()
        defer { server.stop() }
        #expect(try ControlClient.send(ControlRequest(.status), to: socket).notice == "fresh")
    }

    @Test func neverRemovesSomethingThatIsNotASocket() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: socket)
        let server = ControlServer(socket: socket) { _ in ControlResponse() }
        #expect(throws: ControlError.notASocket) { try server.start() }
        #expect(try String(contentsOf: socket, encoding: .utf8) == "keep me")
    }

    @Test func longCommandsKeepTheConnectionOpen() throws {
        let server = ControlServer(socket: socket) { _ in
            try? await Task.sleep(for: .milliseconds(1500))
            return ControlResponse(notice: "done")
        }
        try server.start()
        defer { server.stop() }
        let start = Date()
        #expect(try ControlClient.send(ControlRequest(.refresh), to: socket).notice == "done")
        #expect(Date().timeIntervalSince(start) >= 1.4)
    }

    @Test func clientLeavingCancelsTheCommand() async throws {
        let cancelled = Flag()
        let server = ControlServer(socket: socket) { _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.set()
            }
            return ControlResponse()
        }
        try server.start()
        defer { server.stop() }

        let fd = try UnixSocket.connect(socket.path)
        var line = try ControlWire.encoder.encode(ControlRequest(.connect, id: UUID()))
        line.append(0x0A)
        #expect(UnixSocket.writeAll(fd, line, waitMilliseconds: 1000))
        try await Task.sleep(for: .milliseconds(200))
        close(fd)   // what Ctrl-C does
        for _ in 0..<50 where !cancelled.value { try await Task.sleep(for: .milliseconds(100)) }
        #expect(cancelled.value)
    }

    @Test func garbageGetsAnErrorNotACrash() throws {
        let server = ControlServer(socket: socket) { _ in ControlResponse() }
        try server.start()
        defer { server.stop() }
        let fd = try UnixSocket.connect(socket.path)
        defer { close(fd) }
        #expect(UnixSocket.writeAll(fd, Data("{\"command\":\"format-disk\"}\n".utf8), waitMilliseconds: 1000))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        let reply = try ControlWire.decoder.decode(ControlResponse.self, from: Data(buffer[0..<max(0, n - 1)]))
        #expect(reply.error?.contains("didn't understand") == true)
        // The server still answers afterwards.
        #expect(try ControlClient.send(ControlRequest(.status), to: socket).error == nil)
    }

    @Test func manyClientsAtOnce() throws {
        let server = ControlServer(socket: socket) { request in
            try? await Task.sleep(for: .milliseconds(50))
            return ControlResponse(notice: request.name)
        }
        try server.start()
        defer { server.stop() }
        // Plain threads: blocking clients must not sit on the threads the server's handlers need.
        let names = Names()
        let group = DispatchGroup()
        for i in 0..<20 {
            group.enter()
            Thread { [socket] in
                defer { group.leave() }
                if let name = try? ControlClient.send(ControlRequest(.status, name: "c\(i)"), to: socket).notice { names.add(name) }
            }.start()
        }
        #expect(group.wait(timeout: .now() + 20) == .success)
        #expect(names.count == 20)
    }

    @Test func bigAnswersArriveWhole() throws {
        let many = (0..<400).map { i in
            ControlAccount(id: UUID(), provider: .codex, label: "account-\(i)@example.com", plan: "Plus", state: .idle,
                           usage: UsageSnapshot(windows: [UsageWindow(kind: .weekly, usedPercent: Double(i % 100), resetsAt: Date(timeIntervalSince1970: 1_792_500_000))],
                                                asOf: Date(timeIntervalSince1970: 1_792_000_000), source: "ChatGPT"))
        }
        let server = ControlServer(socket: socket) { _ in ControlResponse(accounts: many) }
        try server.start()
        defer { server.stop() }
        #expect(try ControlClient.send(ControlRequest(.status), to: socket).accounts == many)
    }

    @Test func requestsCarryEveryField() throws {
        let request = ControlRequest(.add, id: UUID(), kind: .grokBot, name: "n", key: "k", region: "china")
        let data = try ControlWire.encoder.encode(request)
        #expect(!data.contains(0x0A))
        #expect(try ControlWire.decoder.decode(ControlRequest.self, from: data) == request)
        #expect(String(decoding: data, as: UTF8.self).contains(#""kind":"grok-bot""#))
    }
}

private final class Names: @unchecked Sendable {
    private let lock = NSLock()
    private var set = Set<String>()
    func add(_ name: String) { _ = lock.withLock { set.insert(name) } }
    var count: Int { lock.withLock { set.count } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    func set() { lock.withLock { _value = true } }
    var value: Bool { lock.withLock { _value } }
}

// MARK: Matching, best, order

@Suite struct ControlMatchTests {
    let claudeMe = ControlAccount(id: UUID(), provider: .claude, label: "me@example.com", state: .open)
    let claudeWork = ControlAccount(id: UUID(), provider: .claude, label: "Work Max", state: .idle)
    let codexMe = ControlAccount(id: UUID(), provider: .codex, label: "me@example.com", state: .active)
    let codexTeam = ControlAccount(id: UUID(), provider: .codex, label: "team@example.com", state: .idle)
    let kimi = ControlAccount(id: UUID(), provider: .kimi, label: "Kimi", state: .active)
    var all: [ControlAccount] { [claudeMe, claudeWork, codexMe, codexTeam, kimi] }

    @Test func exactNameAnyCase() {
        #expect(AccountMatch.find("work max", in: all) == .found(claudeWork))
        #expect(AccountMatch.find("KIMI", in: all) == .found(kimi))
    }

    @Test func sameNameInTwoProductsIsAmbiguous() {
        #expect(AccountMatch.find("me@example.com", in: all) == .ambiguous([claudeMe, codexMe]))
        #expect(AccountMatch.find("codex:me@example.com", in: all) == .found(codexMe))
        #expect(AccountMatch.find("Claude:ME", in: all) == .found(claudeMe))
    }

    @Test func prefixThenSubstring() {
        #expect(AccountMatch.find("team", in: all) == .found(codexTeam))
        #expect(AccountMatch.find("max", in: all) == .found(claudeWork))
        #expect(AccountMatch.find("example", in: all) == .ambiguous([claudeMe, codexMe, codexTeam]))
        // An exact match wins over longer names that start the same way.
        let short = ControlAccount(id: UUID(), provider: .zai, label: "Z", state: .idle)
        let long = ControlAccount(id: UUID(), provider: .zai, label: "Zed", state: .idle)
        #expect(AccountMatch.find("z", in: [short, long]) == .found(short))
    }

    @Test func numbersAndIds() {
        #expect(AccountMatch.find("1", in: all) == .found(claudeMe))
        #expect(AccountMatch.find("5", in: all) == .found(kimi))
        #expect(AccountMatch.find("6", in: all) == .none)
        #expect(AccountMatch.find("0", in: all) == .none)
        #expect(AccountMatch.find(codexTeam.id.uuidString.lowercased(), in: all) == .found(codexTeam))
    }

    @Test func providerAloneOrNothing() {
        #expect(AccountMatch.find("kimi:", in: all) == .found(kimi))
        #expect(AccountMatch.find("codex:", in: all) == .ambiguous([codexMe, codexTeam]))
        #expect(AccountMatch.find("nobody", in: all) == .none)
        #expect(AccountMatch.find("  ", in: all) == .none)
        #expect(AccountMatch.find("grok:me", in: all) == .none)
        // A colon that isn't a provider is part of the name.
        let odd = ControlAccount(id: UUID(), provider: .claude, label: "home: mac", state: .idle)
        #expect(AccountMatch.find("home: mac", in: [odd]) == .found(odd))
    }

    func account(_ provider: Provider, _ label: String, used: [Double], signIn: Bool = false) -> ControlAccount {
        let kinds: [UsageWindow.Kind] = [.fiveHour, .weekly]
        let windows = used.enumerated().map { UsageWindow(kind: kinds[$0.offset], usedPercent: $0.element) }
            + [UsageWindow(kind: .weekly, label: "Opus", usedPercent: 100)]   // scoped windows never count
        return ControlAccount(id: UUID(), provider: provider, label: label, state: .idle,
                              usage: UsageSnapshot(windows: windows, asOf: Date(), source: "test"), needsSignIn: signIn)
    }

    @Test func bestHasTheMostLeftInItsTightestWindow() {
        let a = account(.claude, "a", used: [10, 90])    // 10 left
        let b = account(.claude, "b", used: [60, 50])    // 40 left
        let c = account(.claude, "c", used: [0, 5], signIn: true)   // signed out: never best
        let d = account(.codex, "d", used: [0, 0])
        #expect(ControlAccount.best(of: .claude, in: [a, b, c, d])?.label == "b")
        #expect(ControlAccount.best(of: .codex, in: [a, b, c, d])?.label == "d")
        #expect(ControlAccount.best(of: .kimi, in: [a, b, c, d]) == nil)
        let tie = account(.claude, "tie", used: [60, 60])
        #expect(ControlAccount.best(of: .claude, in: [b, tie])?.label == "b")
        #expect(b.roomLeft == 40)
        #expect(UsageSnapshot(windows: [UsageWindow(kind: .fiveHour, usedPercent: 60), UsageWindow(kind: .weekly, usedPercent: 50)], asOf: Date(), source: "").roomLeft == 40)
    }

    @Test func withNothingLeftBestIsBackSoonest() {
        let now = Date()
        func empty(_ label: String, back minutes: Double?) -> ControlAccount {
            let windows = [UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: minutes.map { now.addingTimeInterval($0 * 60) }),
                           UsageWindow(kind: .weekly, usedPercent: 40, resetsAt: now.addingTimeInterval(86400))]
            return ControlAccount(id: UUID(), provider: .claude, label: label, state: .idle,
                                  usage: UsageSnapshot(windows: windows, asOf: now, source: "test"))
        }
        let unknown = empty("unknown", back: nil), late = empty("late", back: 180), soon = empty("soon", back: 20)
        #expect(ControlAccount.best(of: .claude, in: [unknown, late, soon])?.label == "soon")
        #expect(ControlAccount.best(of: .claude, in: [unknown, late])?.label == "late")
        // Any room at all beats waiting.
        #expect(ControlAccount.best(of: .claude, in: [soon, account(.claude, "some", used: [99, 0])])?.label == "some")
        // Both windows empty: back when the later one refills.
        let both = UsageSnapshot(windows: [UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: now.addingTimeInterval(600)),
                                           UsageWindow(kind: .weekly, usedPercent: 100, resetsAt: now.addingTimeInterval(7200))],
                                 asOf: now, source: "test")
        #expect(both.room?.backAt == now.addingTimeInterval(7200))
    }

    @Test func aPassedResetIsFullAgain() {
        let now = Date()
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: now.addingTimeInterval(-60)),
            UsageWindow(kind: .weekly, usedPercent: 70, resetsAt: now.addingTimeInterval(3600)),
            UsageWindow(kind: .monthly, usedPercent: 20),
        ], asOf: now.addingTimeInterval(-3600), source: "test").at(now)
        #expect(snapshot.window(.fiveHour) == UsageWindow(kind: .fiveHour, usedPercent: 0))
        #expect(snapshot.window(.weekly)?.usedPercent == 70)
        #expect(snapshot.window(.monthly)?.usedPercent == 20)
        #expect(snapshot.roomLeft == 30)
    }

    @Test func displayOrderGroupsLikeThePanel() {
        let zai = ControlAccount(id: UUID(), provider: .zai, label: "Z.ai", state: .idle)
        let mixed = [kimi, codexMe, zai, claudeWork, codexTeam, claudeMe]
        #expect(ControlAccount.inDisplayOrder(mixed).map(\.label) == ["Work Max", "me@example.com", "me@example.com", "team@example.com", "Kimi", "Z.ai"])
    }

    @Test func providerNames() {
        #expect(Provider(cliName: "Z.AI") == .zai)
        #expect(Provider(cliName: "zai") == .zai)
        #expect(Provider(cliName: "Claude") == .claude)
        #expect(Provider(cliName: "gemini") == nil)
    }
}

// MARK: Text and JSON

@Suite struct StatusTextTests {
    let utc = TimeZone(identifier: "UTC")!
    /// Tuesday 2026-10-20 10:00 UTC.
    let now = Date(timeIntervalSince1970: 1_792_490_400)

    func text(color: Bool = false) -> StatusText { StatusText(now: now, color: color, timeZone: utc) }

    var accounts: [ControlAccount] {
        [
            ControlAccount(id: UUID(), provider: .claude, label: "me@example.com", plan: "Max", state: .open,
                           usage: UsageSnapshot(windows: [
                               UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: now.addingTimeInterval(72 * 60 + 5)),
                               UsageWindow(kind: .weekly, usedPercent: 85, resetsAt: now.addingTimeInterval(2 * 86400 + 3600)),
                               UsageWindow(kind: .weekly, label: "Opus", usedPercent: 3),
                           ], asOf: now.addingTimeInterval(-60), source: "Claude Code")),
            ControlAccount(id: UUID(), provider: .claude, label: "work@example.com", plan: "Team", state: .idle,
                           usage: UsageSnapshot(windows: [
                               UsageWindow(kind: .fiveHour, usedPercent: 2, resetsAt: now.addingTimeInterval(4 * 3600 + 21 * 60 + 5)),
                               UsageWindow(kind: .weekly, usedPercent: 14),
                           ], asOf: now.addingTimeInterval(-3 * 3600), source: "Claude app"),
                           pendingSessions: 3, best: true),
            ControlAccount(id: UUID(), provider: .codex, label: "me@example.com", plan: "Pro", state: .active,
                           usage: UsageSnapshot(windows: [UsageWindow(kind: .weekly, usedPercent: 99.6, resetsAt: now.addingTimeInterval(20 * 86400))],
                                                credits: Credits(amount: 1200, currency: "credits", label: "balance"), resetsAvailable: 1,
                                                asOf: now, source: "ChatGPT")),
            ControlAccount(id: UUID(), provider: .kimi, label: "Kimi", state: .idle, error: "Key no longer works", needsSignIn: true),
            ControlAccount(id: UUID(), provider: .zai, label: "work key", plan: "Pro", state: .active,
                           usage: UsageSnapshot(windows: [UsageWindow(kind: .monthly, usedPercent: 0, resetsAt: now.addingTimeInterval(30))],
                                                credits: Credits(amount: 12.4, currency: "USD", label: "balance"), asOf: now, source: "API key")),
            ControlAccount(id: UUID(), provider: .claude, label: "new", state: .idle, error: "Sign in again", needsSignIn: true),
        ]
    }

    @Test func theWholeStatus() {
        let out = text().render(ControlAccount.inDisplayOrder(accounts))
        let expected = """
        Claude
        1 ● me@example.com    Max
            5h  ──────────  empty · back in 1h 12m
            7d  ━━────────   15% left · resets Thu
        2 ○ work@example.com  Team  ✦
            5h  ━━━━━━━━━━   98% left · resets in 4h 21m
            7d  ━━━━━━━━━─   86% left
            3 new sessions · openaccs restart 2 · updated 3h ago
        3 ○ new
            Sign in again · openaccs connect 3

        Codex
        4 ● me@example.com    Pro
            7d  ━─────────  <1% left · resets Nov 9
            1 reset left · 1,200 credits

        Limits
        5 ○ Kimi
            Key no longer works
        6 ● work key · Z.ai   Pro
            mo  ━━━━━━━━━━  100% left · resets now
            $12.40 balance

        """
        #expect(out == expected)
        #expect(!out.contains("\u{1B}"))
    }

    @Test func oneProviderKeepsTheGlobalNumbers() {
        let out = text().render(ControlAccount.inDisplayOrder(accounts), only: .codex)
        #expect(out.hasPrefix("Codex\n4 ● me@example.com"))
        #expect(!out.contains("Claude"))
        #expect(text().render(accounts, only: .grok) == "No Grok accounts. Add one: openaccs add grok\n")
        #expect(text().render([]) == "No accounts yet. Add one: openaccs add claude <name>\n")
    }

    @Test func colorOnlyWhenAsked() {
        let out = text(color: true).render(accounts, notice: "accounts.json couldn't be read")
        #expect(out.contains("\u{1B}[33maccounts.json couldn't be read\u{1B}[0m"))
        #expect(out.contains("\u{1B}[31mempty\u{1B}[0m"))
        #expect(out.contains("\u{1B}[1mClaude\u{1B}[0m"))
    }

    @Test func remainingWords() {
        func w(_ used: Double) -> ControlAccount.Window { .init(UsageWindow(kind: .fiveHour, usedPercent: used)) }
        #expect(StatusText.left(w(38)) == " 62% left")
        #expect(StatusText.left(w(37.5)) == " 62% left")
        #expect(StatusText.left(w(0)) == "100% left")
        #expect(StatusText.left(w(95)) == "  5% left")
        #expect(StatusText.left(w(99.5)) == "<1% left")
        #expect(StatusText.left(w(100)) == "empty")
        #expect(w(38).leftPercent == 62)
    }

    @Test func resetsAndStaleness() {
        let t = text()
        #expect(t.reset(nil, empty: false) == nil)
        #expect(t.reset(now.addingTimeInterval(20), empty: false) == "resets now")
        #expect(t.reset(now.addingTimeInterval(-600), empty: true) == "back any minute")
        #expect(t.reset(now.addingTimeInterval(42 * 60 + 5), empty: false) == "resets in 42m")
        #expect(t.reset(now.addingTimeInterval(3 * 3600 + 5), empty: true) == "back in 3h")
        #expect(t.reset(now.addingTimeInterval(86400 * 3), empty: false) == "resets Fri")
        #expect(t.reset(now.addingTimeInterval(86400 * 10), empty: false) == "resets Oct 30")
        #expect(t.stale(now.addingTimeInterval(-29 * 60)) == nil)
        #expect(t.stale(now.addingTimeInterval(-35 * 60)) == "updated 35m ago")
        #expect(t.stale(now.addingTimeInterval(-2 * 3600)) == "updated 2h ago")
        #expect(t.stale(now.addingTimeInterval(-2 * 86400)) == "updated Oct 18")
    }

    @Test func bestOnItsOwn() {
        let a = accounts[1]
        #expect(text().render(a, number: 2) == """
        2 ○ work@example.com  Team  ✦
            5h  ━━━━━━━━━━   98% left · resets in 4h 21m
            7d  ━━━━━━━━━─   86% left
            3 new sessions · openaccs restart 2 · updated 3h ago

        """)
    }

    @Test func jsonSchema() throws {
        let json = ControlAccount.json(Array(accounts.prefix(1)))
        let root = try #require(JSON.object(Data(json.utf8)))
        let account = try #require((root["accounts"] as? [[String: Any]])?.first)
        #expect(Set(account.keys) == ["id", "provider", "label", "plan", "state", "windows", "asOf", "source", "needsSignIn", "pendingSessions", "best"])
        #expect(account["state"] as? String == "open")
        #expect(account["provider"] as? String == "claude")
        let windows = try #require(account["windows"] as? [[String: Any]])
        #expect(windows.count == 3)
        #expect(windows[1]["kind"] as? String == "weekly")
        #expect(windows[1]["leftPercent"] as? Double == 15)
        #expect(windows[1]["usedPercent"] as? Double == 85)
        #expect(windows[1]["resetsAt"] as? String == "2026-10-22T11:00:00Z")
        #expect(windows[2]["label"] as? String == "Opus")
        #expect(account["asOf"] as? String == "2026-10-20T09:59:00Z")

        let one = try #require(JSON.object(Data(ControlAccount.json(accounts[2]).utf8)))
        #expect((one["credits"] as? [String: Any])?["amount"] as? Double == 1200)
        #expect(one["resetsAvailable"] as? Int == 1)
        // Decodes back to the same thing.
        let decoded = try ControlWire.decoder.decode([String: [ControlAccount]].self, from: Data(ControlAccount.json(accounts).utf8))
        #expect(decoded["accounts"]?.map(\.label) == accounts.map(\.label))
    }
}
