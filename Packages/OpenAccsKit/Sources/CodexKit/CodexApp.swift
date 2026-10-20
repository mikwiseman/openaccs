import AppKit
import Foundation
import OpenAccsCore

/// Everything a switch or sign-in does to the real Mac, behind one seam so tests never touch real apps.
public protocol CodexAppControl: Sendable {
    /// True while any process from the Codex app bundle runs (the app, its app-servers, the bundled CLI).
    func isRunning() -> Bool
    /// Asks the app to quit (like ⌘Q) and waits until no process from its bundle remains. False on timeout.
    func quit(timeout: Duration) async -> Bool
    /// Opens the app, or brings it forward when it already runs.
    func launch() async throws
    /// `codex app-server daemon restart`, so the shared background server loads the new sign-in.
    func restartDaemon() async throws
    /// `codex login` with `CODEX_HOME=<codexHome>`; returns when the CLI exits.
    func login(codexHome: URL, timeout: Duration) async throws
}

/// The real Codex desktop app (`/Applications/ChatGPT.app`) and its bundled CLI.
public struct CodexApp: CodexAppControl {
    public var paths: Paths

    public init(paths: Paths = Paths()) { self.paths = paths }

    /// The CLI bundled with the app, else `codex` on PATH.
    public func executable() -> URL? {
        let bundled = paths.codexApp.appending(path: "Contents/Resources/codex-cli/bin/codex")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        return dirs.map { URL(filePath: String($0)).appending(path: "codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func isRunning() -> Bool {
        let prefix = CodexAccounts.bundlePrefix(paths.codexApp)
        return ProcessList.all().contains { $0.path.hasPrefix(prefix) }
    }

    public func quit(timeout: Duration) async -> Bool {
        await MainActor.run {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: BundleIDs.codex) {
                app.terminate()
            }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while isRunning() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }

    @MainActor
    public func launch() async throws {
        _ = try await NSWorkspace.shared.openApplication(at: paths.codexApp, configuration: NSWorkspace.OpenConfiguration())
    }

    public func restartDaemon() async throws {
        try await run(["app-server", "daemon", "restart"], environment: ProcessRunner.cleanEnvironment(), timeout: .seconds(60))
    }

    public func login(codexHome: URL, timeout: Duration) async throws {
        // Force the file store so the login lands in <codexHome>/auth.json, never in the keychain.
        try await run(
            ["login", "-c", #"cli_auth_credentials_store="file""#],
            environment: ProcessRunner.cleanEnvironment(adding: ["CODEX_HOME": codexHome.path]),
            directory: codexHome, timeout: timeout
        )
    }

    private func run(_ arguments: [String], environment: [String: String], directory: URL? = nil, timeout: Duration) async throws {
        guard let exe = executable() else { throw ProcessError.notFound("codex") }
        let result = try await ProcessRunner.run(exe, arguments, environment: environment, currentDirectory: directory, timeout: timeout)
        guard result.status == 0 else {
            let command = arguments.prefix { !$0.hasPrefix("-") }.joined(separator: " ")
            throw ProcessError.failed("codex \(command)", result.status, result.stderrString)
        }
    }
}
