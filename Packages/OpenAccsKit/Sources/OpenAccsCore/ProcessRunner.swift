import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessError: Error, Sendable, LocalizedError {
    case notFound(String)
    case timedOut(String)
    case failed(String, Int32, String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let p): "Not found: \(p)"
        case .timedOut(let p): "Timed out: \(p)"
        case .failed(let p, let code, let err): "\(p) exited \(code): \(err.prefix(300))"
        }
    }
}

/// Runs a command to completion. `environment` replaces the inherited one when given
/// (build it from `ProcessRunner.cleanEnvironment()` to drop CLAUDE_*/ANTHROPIC_* leaks).
public enum ProcessRunner {
    /// Variables that would make a child app or CLI use another account or config folder.
    public static func isAccountVariable(_ key: String) -> Bool {
        key.hasPrefix("CLAUDE") || key.hasPrefix("ANTHROPIC") || key.hasPrefix("CODEX_") || key.hasPrefix("OPENAI")
            || key.hasPrefix("GROK_") || key == "XPC_SERVICE_NAME"
    }

    /// Removes account variables from this process, so apps launched through NSWorkspace (which inherit our
    /// environment and can't be given a reduced one) never start on another profile's config folder.
    public static func scrubOwnEnvironment() {
        for key in ProcessInfo.processInfo.environment.keys where isAccountVariable(key) { unsetenv(key) }
    }

    public static func run(
        _ executable: URL, _ arguments: [String] = [], environment: [String: String]? = nil,
        currentDirectory: URL? = nil, stdin: Data? = nil, timeout: Duration = .seconds(30)
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessError.notFound(executable.path)
        }
        ignoreSIGPIPE()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input

        let collector = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { h in collector.appendOut(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in collector.appendErr(h.availableData) }

        // Cancelling the calling task (e.g. the user pressed Cancel during a sign-in) ends the child.
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                    return
                }
                if Task.isCancelled { process.terminate() }
                if let stdin { try? input.fileHandleForWriting.write(contentsOf: stdin) }
                try? input.fileHandleForWriting.close()
                Task {
                    try? await Task.sleep(for: timeout)
                    if process.isRunning {
                        collector.markTimedOut()
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
        collector.appendErr(err.fileHandleForReading.readDataToEndOfFile())
        if collector.timedOut { throw ProcessError.timedOut(executable.lastPathComponent) }
        try Task.checkCancellation()
        return ProcessResult(status: status, stdout: collector.out, stderr: collector.err)
    }

    /// The current environment minus variables that would change which account a child CLI uses.
    public static func cleanEnvironment(adding extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in !isAccountVariable(key) }
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        env.merge(extra) { _, new in new }
        return env
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data(), _err = Data(), _timedOut = false
    func appendOut(_ d: Data) { lock.withLock { _out.append(d) } }
    func appendErr(_ d: Data) { lock.withLock { _err.append(d) } }
    func markTimedOut() { lock.withLock { _timedOut = true } }
    var out: Data { lock.withLock { _out } }
    var err: Data { lock.withLock { _err } }
    var timedOut: Bool { lock.withLock { _timedOut } }
}

/// A long-lived child speaking newline-delimited JSON over stdin/stdout
/// (Claude Code `--input-format stream-json`, `grok agent stdio`).
public final class LineProcess: @unchecked Sendable {
    public let lines: AsyncStream<String>
    private let process = Process()
    private let input = Pipe()
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var buffer = Data()

    public init(_ executable: URL, _ arguments: [String], environment: [String: String], currentDirectory: URL? = nil) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessError.notFound(executable.path)
        }
        (lines, continuation) = AsyncStream<String>.makeStream()
        ignoreSIGPIPE()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        let cont = continuation
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                cont.finish()
                return
            }
            self?.consume(data)
        }
        process.terminationHandler = { _ in cont.finish() }
        try process.run()
    }

    private func consume(_ data: Data) {
        let complete: [String] = lock.withLock {
            buffer.append(data)
            var result: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                result.append(String(decoding: line, as: UTF8.self))
            }
            return result
        }
        for line in complete where !line.isEmpty { continuation.yield(line) }
    }

    public func send(_ line: String) {
        guard process.isRunning else { return }
        // Throwing write: a child that just exited gives EPIPE instead of killing us.
        try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    public func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(String(decoding: data, as: UTF8.self))
    }

    /// Waits for the first line whose JSON satisfies `match`, up to `timeout`.
    public func firstJSON(timeout: Duration, where match: @escaping @Sendable ([String: Any]) -> Bool) async -> [String: Any]? {
        let line: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { [lines] in
                for await line in lines {
                    if let obj = JSON.object(Data(line.utf8)), match(obj) { return line }
                }
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

    /// Closes stdin and lets the child exit on its own; SIGTERM only after `grace`.
    /// Use this for vendor CLIs that may be saving a rotated login token when we are done with them.
    public func finish(grace: Duration = .seconds(10)) async {
        try? input.fileHandleForWriting.close()
        let clock = ContinuousClock()
        let deadline = clock.now + grace
        while process.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        terminate()
    }

    public func terminate() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        continuation.finish()
    }

    deinit { terminate() }
}

/// Writing to a pipe whose reader died must be an error, not a fatal signal.
private let sigpipeIgnored: Void = { signal(SIGPIPE, SIG_IGN) }()
func ignoreSIGPIPE() { _ = sigpipeIgnored }
