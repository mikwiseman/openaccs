import Foundation
import OpenAccsCore

/// Who the CLI is signed in as: `<configDir>/.claude.json` `oauthAccount`.
public struct ClaudeCLIIdentity: Sendable, Hashable {
    public var email: String?
    public var organization: String?
    /// Compare with the window's account: the browser may sign the CLI in to a different one.
    public var accountUuid: String?
    public var organizationUuid: String? = nil

    /// Signed in to that account, and to that org when the CLI names one.
    public func matches(_ key: ClaudeAccountKey) -> Bool {
        guard accountUuid?.lowercased() == key.account else { return false }
        return organizationUuid.map { $0.lowercased() == key.org } ?? true
    }

    /// The same account, and the same org when both name one.
    func isSame(as other: ClaudeCLIIdentity) -> Bool {
        guard let account = accountUuid?.lowercased(), account == other.accountUuid?.lowercased() else { return false }
        guard let org = organizationUuid?.lowercased(), let otherOrg = other.organizationUuid?.lowercased() else { return true }
        return org == otherOrg
    }
}

/// Live Claude limits through Anthropic's unmodified `claude` CLI, signed in once per account and org in an
/// OpenAccs-owned CLAUDE_CONFIG_DIR. OpenAccs never reads the CLI's credentials. It only asks the CLI, and
/// reads the account and org in that folder's `.claude.json` to know whose numbers they are.
public struct ClaudeCodeCLI: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    /// `~/.local/bin/claude` (resolved), else the newest desktop-bundled CLI. Never a `claude` under `~/.codex` (wrappers, not the real CLI).
    public func executable() -> URL? {
        let installed = paths.home.appending(path: ".local/bin/claude").resolvingSymlinksInPath()
        if isUsable(installed) { return installed }
        let root = paths.claudeDefaultDataDir.appending(path: "claude-code", directoryHint: .isDirectory)
        let fm = FileManager.default
        let versions = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in versions {
            let dir = root.appending(path: version, directoryHint: .isDirectory)
            for hash in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
                let candidate = dir.appending(path: "\(hash)/claude.app/Contents/MacOS/claude")
                if isUsable(candidate) { return candidate }
            }
        }
        return nil
    }

    private func isUsable(_ url: URL) -> Bool {
        let codex = paths.codexHome.resolvingSymlinksInPath().path + "/"
        let resolved = url.resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        return !resolved.hasPrefix(codex) && !url.path.hasPrefix(paths.codexHome.path + "/")
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// `<appSupport>/Claude Code/<id>`: a new folder for each sign-in, with no trailing slash. The CLI names its
    /// Keychain item after this exact string, so a stored path is used verbatim forever.
    public func configDir(for signIn: UUID) -> URL {
        paths.claudeSignInsDir.appending(path: signIn.uuidString, directoryHint: .notDirectory)
    }

    /// Runs Anthropic's own sign-in (`claude auth login --claudeai`) in that folder and waits up to 10 minutes.
    /// The CLI hands its link to `$BROWSER`: a small helper only writes it down, and `onLink` gets it once,
    /// while the CLI waits, so the caller opens it (in a private window when it can). A browser signed in to
    /// claude.ai as another account can't finish it (claude.ai says "Unable to access Claude Code").
    public func login(configDir: URL, email: String?, onLink: @escaping @Sendable (URL) -> Void = { _ in }) async throws {
        guard let claude = executable() else { throw ProcessError.notFound("claude") }
        try FS.makeDirectory(configDir)
        var arguments = ["auth", "login", "--claudeai"]
        if let email, !email.isEmpty { arguments += ["--email", email] }
        // Outside Application Support: a path with spaces may not survive as $BROWSER.
        let scratch = FileManager.default.temporaryDirectory.appending(path: "openaccs-sign-in-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FS.makeDirectory(scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let link = scratch.appending(path: "link"), helper = scratch.appending(path: "open")
        try AtomicFile.write(Data("#!/bin/sh\nprintf '%s' \"$1\" > \(Self.quoted(link.path))\n".utf8), to: helper, permissions: 0o700)
        let watch = Task {
            while !Task.isCancelled {
                if let text = try? String(contentsOf: link, encoding: .utf8), let url = URL(string: text), url.scheme == "https" {
                    onLink(url)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watch.cancel() }
        var environment = environment(configDir)
        environment["BROWSER"] = helper.path
        let result = try await ProcessRunner.run(
            claude, arguments, environment: environment, currentDirectory: try neutralDirectory(), timeout: .seconds(600)
        )
        // No link after the CLI exits: nobody listens for its sign-in anymore.
        guard result.status == 0 else { throw ProcessError.failed("claude auth login", result.status, result.stderrString) }
    }

    /// For a POSIX shell: single quotes, with any single quote spelled out.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Who the CLI is signed in as: `<dir>/.claude.json` `oauthAccount`. nil when not signed in.
    public func identity(configDir: URL) -> ClaudeCLIIdentity? {
        guard let data = try? Data(contentsOf: configDir.appending(path: ".claude.json")),
              let account = JSON.object(data)?["oauthAccount"] as? [String: Any] else { return nil }
        return ClaudeCLIIdentity(
            email: account["emailAddress"] as? String, organization: account["organizationName"] as? String,
            accountUuid: account["accountUuid"] as? String, organizationUuid: account["organizationUuid"] as? String
        )
    }

    /// Per account and org, the first of `dirs` whose CLI is signed in to it, returned exactly as given
    /// (the CLI names its Keychain item after the exact string). A folder in `signedOut` serves only when its
    /// account has no other. Reads each folder's `.claude.json` once.
    public func signIns(_ dirs: [String], for keys: Set<ClaudeAccountKey>, signedOut: Set<String> = []) -> [ClaudeAccountKey: String] {
        var result: [ClaudeAccountKey: String] = [:], read = Set<String>()
        for dir in dirs.filter({ !signedOut.contains($0) }) + dirs.filter({ signedOut.contains($0) }) where read.insert(dir).inserted {
            guard let who = identity(configDir: URL(filePath: dir, directoryHint: .isDirectory)) else { continue }
            for key in keys where result[key] == nil && who.matches(key) { result[key] = dir }
        }
        return result
    }

    /// The windows a new sign-in as `who` goes to: every window showing that account and org, plus every
    /// window still holding an older folder signed in to it, so the account keeps exactly one folder.
    public func sharing(_ who: ClaudeCLIIdentity, among windows: [(id: UUID, key: ClaudeAccountKey?, dir: String?)]) -> [UUID] {
        windows.filter { window in
            if let key = window.key, who.matches(key) { return true }
            guard let dir = window.dir, let held = identity(configDir: URL(filePath: dir, directoryHint: .isDirectory)) else { return false }
            return held.isSame(as: who)
        }.map(\.id)
    }

    /// The switch that opens a link in a private window of that browser (by bundle id). nil when OpenAccs
    /// knows none: Safari and the rest open the link normally.
    public static func privateWindowFlag(browser bundleID: String) -> String? {
        let id = bundleID.lowercased()
        let flags = [
            ("com.google.chrome", "--incognito"), ("com.brave.browser", "--incognito"), ("org.chromium.chromium", "--incognito"),
            ("com.microsoft.edgemac", "--inprivate"),
            ("org.mozilla.firefox", "--private-window"), ("org.mozilla.firefoxdeveloperedition", "--private-window"),
            ("org.mozilla.nightly", "--private-window"),
        ]
        return flags.first { id == $0.0 || id.hasPrefix($0.0 + ".") }?.1
    }

    /// Asks the CLI for plan limits (`get_usage` control request over stream-json). Never sends a prompt.
    public func usage(configDir: URL) async throws -> UsageSnapshot {
        guard ClaudeProfiles.directoryExists(configDir) else { throw UsageError.notConnected }
        guard let claude = executable() else { throw UsageError.unexpected("Claude Code is not installed") }
        let process = try LineProcess(
            claude,
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence"],
            environment: environment(configDir), currentDirectory: try neutralDirectory()
        )
        let id = "openaccs-usage-\(UUID().uuidString)"
        process.send(json: ["type": "control_request", "request_id": "openaccs-init", "request": ["subtype": "initialize"]])
        process.send(json: ["type": "control_request", "request_id": id, "request": ["subtype": "get_usage", "skip_behaviors": true]])
        let reply = await process.firstJSON(timeout: .seconds(20)) { message in
            message["type"] as? String == "control_response" && (message["response"] as? [String: Any])?["request_id"] as? String == id
        }
        // Let the CLI exit on stdin EOF: it may be saving a refreshed (rotated) login token.
        await process.finish(grace: .seconds(10))
        guard let reply else { throw UsageError.unexpected("Claude Code did not answer") }
        return try Self.parseUsage(reply, now: Date())
    }

    /// The CLI's environment minus every CLAUDE_*/ANTHROPIC_* variable, plus this account's config dir.
    func environment(_ configDir: URL) -> [String: String] {
        ProcessRunner.cleanEnvironment(adding: ["CLAUDE_CONFIG_DIR": configDir.path])
    }

    /// An empty working folder, so the CLI never picks up a project's settings or hooks.
    func neutralDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "openaccs-claude-cwd", directoryHint: .isDirectory)
        try FS.makeDirectory(dir)
        return dir
    }

    // MARK: Parsing

    /// Maps a `get_usage` control_response to a snapshot.
    static func parseUsage(_ message: [String: Any], now: Date) throws -> UsageSnapshot {
        guard let response = message["response"] as? [String: Any] else { throw UsageError.unexpected("Unexpected Claude Code reply") }
        if response["subtype"] as? String == "error" {
            throw UsageError.unexpected((response["error"] as? String) ?? "Claude Code could not read usage")
        }
        guard let body = response["response"] as? [String: Any] else { throw UsageError.unexpected("Unexpected Claude Code reply") }
        guard body["rate_limits_available"] as? Bool == true else { throw UsageError.notConnected }
        guard let limits = body["rate_limits"] as? [String: Any] else { throw UsageError.unexpected("Claude Code returned no limits") }

        var windows: [UsageWindow] = []
        func add(_ value: Any?, _ kind: UsageWindow.Kind, _ label: String?) {
            guard let window = value as? [String: Any], let used = JSON.double(window["utilization"]),
                  !windows.contains(where: { $0.kind == kind && $0.label?.lowercased() == label?.lowercased() }) else { return }
            windows.append(UsageWindow(kind: kind, label: label, usedPercent: used, resetsAt: date(window["resets_at"])))
        }
        add(limits["five_hour"], .fiveHour, nil)
        add(limits["seven_day"], .weekly, nil)
        add(limits["seven_day_opus"], .weekly, "Opus")
        add(limits["seven_day_sonnet"], .weekly, "Sonnet")
        for row in (limits["model_scoped"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            if let name = row["display_name"] as? String, !name.isEmpty { add(row, .weekly, name) }
        }

        var credits: Credits?
        if let extra = limits["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let used = JSON.double(extra["used_credits"]) {
            // Amounts are in minor units of the currency (cents for USD).
            let currency = (extra["currency"] as? String).map { $0.uppercased() }.flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
            credits = Credits(amount: used / pow(10, Double(minorUnitDigits(currency))), currency: currency, label: "extra usage")
        }

        let plan = (body["subscription_type"] as? String).flatMap { $0.isEmpty ? nil : $0.prefix(1).uppercased() + $0.dropFirst() }
        return UsageSnapshot(plan: plan, windows: windows, credits: credits, asOf: now, source: "Claude Code")
    }

    /// ISO 8601 with or without fractional seconds (any number of digits), or epoch numbers.
    static func date(_ value: Any?) -> Date? {
        if let date = JSON.date(value) { return date }
        guard let string = value as? String, let fraction = string.range(of: #"\.\d+"#, options: .regularExpression) else { return nil }
        return JSON.date(string.replacingCharacters(in: fraction, with: ""))
    }

    /// Decimal places of a currency's minor unit (USD 2, JPY 0).
    static func minorUnitDigits(_ currency: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.maximumFractionDigits
    }
}
