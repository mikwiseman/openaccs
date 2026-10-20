import Foundation
import OpenAccsCore

/// SuperGrok / Grok Build limits through the official `grok` CLI. **Experimental**: `_x.ai/billing` is an
/// undocumented ACP extension of `grok agent stdio`.
///
/// Each account gets an OpenAccs-owned GROK_HOME, signed in once with `grok login`. Usage is asked of the CLI
/// itself so it keeps owning its 6-hour token and the rotating refresh token; OpenAccs never reads a token.
public struct GrokCLI: Sendable {
    let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    /// `~/.grok/bin/grok`, else `grok` on PATH.
    public func executable() -> URL? {
        let installed = paths.grokCLIHome.appending(path: "bin/grok")
        if FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        return dirs.lazy.map { URL(filePath: String($0)).appending(path: "grok") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `<appSupport>/Grok/<id>`.
    public func home(for accountID: UUID) -> URL {
        paths.grokHomesDir.appending(path: accountID.uuidString)
    }

    /// Runs the CLI's own browser sign-in (`grok login`) with GROK_HOME = `home`. Waits up to 10 minutes.
    public func login(home: URL) async throws {
        guard let grok = executable() else { throw ProcessError.notFound("grok") }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let result = try await ProcessRunner.run(grok, ["login"], environment: environment(home), currentDirectory: home, timeout: .seconds(600))
        guard result.status == 0 else { throw ProcessError.failed("grok login", result.status, result.stderrString) }
    }

    /// The signed-in email, from the clear-text fields of `<home>/auth.json` (the xAI OIDC entry first).
    public func identity(home: URL) -> String? {
        guard let data = try? Data(contentsOf: home.appending(path: "auth.json")), let store = JSON.object(data) else { return nil }
        let xai = "https://auth.x.ai"
        return store.sorted { $0.key.hasPrefix(xai) && !$1.key.hasPrefix(xai) }
            .lazy.compactMap { nonEmpty(($0.value as? [String: Any])?["email"]) }.first
    }

    /// Experimental. `GROK_HOME=<home> grok agent stdio`, then `initialize` and `_x.ai/billing` over JSON-RPC.
    public func usage(home: URL) async throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: home.appending(path: "auth.json").path) else { throw UsageError.notConnected }
        guard let grok = executable() else { throw UsageError.unexpected("Grok CLI not installed") }
        let agent = try RPCProcess(grok, ["agent", "stdio"], environment: environment(home), currentDirectory: home)
        defer { agent.finish(grace: .seconds(10)) }

        let initialize = await agent.request("initialize", params: ["protocolVersion": 1, "clientCapabilities": [String: Any]()], timeout: .seconds(30))
        guard initialize?["result"] != nil else { throw UsageError.unexpected("Grok CLI did not start") }
        // The billing call uses the stored token even when expired; the agent refreshes it in the background
        // about a second after launch. So an upstream failure is retried twice, 2 s apart.
        for attempt in 1...3 {
            let reply = await agent.request("_x.ai/billing", params: [:], timeout: .seconds(20))
            if let result = reply?["result"] as? [String: Any] { return Self.snapshot(billing: result, now: Date()) }
            let (error, retry) = Self.billingError(reply)
            guard retry, attempt < 3 else { throw error }
            try await Task.sleep(for: .seconds(2))
        }
        throw UsageError.unexpected("Grok CLI did not answer")
    }

    private func environment(_ home: URL) -> [String: String] {
        ProcessRunner.cleanEnvironment(adding: ["GROK_HOME": home.path])
    }

    /// Maps the `_x.ai/billing` result `{config:{creditUsagePercent, currentPeriod{type,start,end}, prepaidBalance{val}, …},
    /// subscription_tier}`.
    static func snapshot(billing: [String: Any], now: Date) -> UsageSnapshot {
        let plan = nonEmpty(billing["subscription_tier"]) ?? nonEmpty(billing["subscriptionTier"])
        guard let config = billing["config"] as? [String: Any] else {
            return UsageSnapshot(plan: plan, windows: [], asOf: now, source: "Grok CLI")
        }
        let period = config["currentPeriod"] as? [String: Any]
        var windows: [UsageWindow] = []
        // proto3 JSON omits zeros, so with a current period a missing percent means 0 %.
        if let percent = JSON.double(config["creditUsagePercent"]) ?? (period != nil ? 0 : nil) {
            let resetsAt = JSON.date(period?["end"]) ?? JSON.date(config["billingPeriodEnd"])
            windows.append(UsageWindow(kind: kind(period), usedPercent: percent, resetsAt: resetsAt))
        }
        // USD cents, sent as negative cents by billing; `{}` is $0.
        let cents = abs(JSON.double((config["prepaidBalance"] as? [String: Any])?["val"]) ?? 0)
        let credits = cents > 0 ? Credits(amount: cents / 100, currency: "USD", label: "balance") : nil
        return UsageSnapshot(plan: plan, windows: windows, credits: credits, asOf: now, source: "Grok CLI")
    }

    /// `USAGE_PERIOD_TYPE_WEEKLY | _MONTHLY`, else the period length.
    static func kind(_ period: [String: Any]?) -> UsageWindow.Kind {
        let type = period?["type"] as? String ?? ""
        if type.hasSuffix("WEEKLY") { return .weekly }
        if type.hasSuffix("MONTHLY") { return .monthly }
        guard let start = JSON.date(period?["start"]), let end = JSON.date(period?["end"]) else { return .other }
        return end.timeIntervalSince(start) <= 8 * 86400 ? .weekly : .monthly
    }

    /// ACP auth_required (-32000) = no usable login in this home. "Billing service error: …" is the upstream
    /// call failing (an expired token until the background refresh lands), worth a retry.
    static func billingError(_ reply: [String: Any]?) -> (UsageError, retry: Bool) {
        guard let error = reply?["error"] as? [String: Any] else { return (.unexpected("Grok CLI did not answer"), false) }
        if JSON.double(error["code"]) == -32000 { return (.notConnected, false) }
        let detail = nonEmpty(error["data"]) ?? nonEmpty(error["message"]) ?? "error"
        guard detail.hasPrefix("Billing service error") else { return (.unexpected("Grok: " + detail.prefix(200)), false) }
        return (detail.contains("401") ? .needsSignIn : .unexpected("Grok: " + detail.prefix(200)), true)
    }
}

/// A child speaking newline-delimited JSON-RPC 2.0 on stdin/stdout. Unlike `LineProcess`, `finish` closes stdin
/// and lets the child exit on its own: `grok agent stdio` drains for ~2 s on EOF but dies at once on SIGTERM,
/// which could cut off a token refresh before the rotated token reaches disk.
final class RPCProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var buffer = Data()
    private var lastID = 0

    init(_ executable: URL, _ arguments: [String], environment: [String: String], currentDirectory: URL) throws {
        (lines, continuation) = AsyncStream<String>.makeStream()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let continuation = continuation
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            self?.consume(data)
        }
        try process.run()
    }

    private func consume(_ data: Data) {
        let complete: [String] = lock.withLock {
            buffer.append(data)
            var result: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                result.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return result
        }
        for line in complete where !line.isEmpty { continuation.yield(line) }
    }

    /// Sends a request; returns the reply with the same id (`result` or `error`), or nil on timeout or exit.
    func request(_ method: String, params: [String: Any], timeout: Duration) async -> [String: Any]? {
        let id = lock.withLock { lastID += 1; return lastID }
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes),
              (try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))) != nil
        else { return nil }
        let line: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { [lines] in
                for await line in lines where Self.id(of: line) == id { return line }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return line.flatMap { JSON.object(Data($0.utf8)) }
    }

    private static func id(of line: String) -> Int? {
        JSON.double(JSON.object(Data(line.utf8))?["id"]).map { Int($0) }
    }

    /// Closes stdin; terminates the child only if it is still running after `grace`.
    func finish(grace: Duration) {
        try? input.fileHandleForWriting.close()
        Task { [self] in
            try? await Task.sleep(for: grace)
            if process.isRunning { process.terminate() }
        }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}
