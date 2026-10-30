import Darwin
import Foundation
import OpenAccsCore
import SetupKit

/// `openaccs …`: a thin client of the running app. Every command goes through the app's control socket and the
/// same AppModel actions as the panel, so behavior and safety are identical. Never creates the app's UI.
enum CLI {
    /// `openaccs` (the ~/.local/bin link) or `OpenAccs.app/Contents/MacOS/OpenAccs cli …`. The name is matched
    /// exactly: the app's own executable is "OpenAccs", and launching the app must stay launching the app.
    static func isRequested(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        return URL(filePath: first).lastPathComponent == "openaccs" || args.dropFirst().first == "cli"
    }

    /// Runs one command. Exit codes: 0 ok, 1 error, 2 usage, 3 OpenAccs not reachable.
    static func run(_ args: [String]) -> Int32 {
        var words = Array(args.dropFirst())
        if words.first == "cli" { words.removeFirst() }
        do {
            try Command(words).run()
            return 0
        } catch let failure as Failure {
            if !failure.message.isEmpty { Terminal.error(failure.message) }
            return failure.code
        } catch let error as ControlError {
            Terminal.error(error.localizedDescription)
            return error == .unreachable ? 3 : 1
        } catch {
            Terminal.error(error.localizedDescription)
            return 1
        }
    }
}

private struct Failure: Error {
    var code: Int32
    var message: String

    static func error(_ message: String) -> Failure { Failure(code: 1, message: message) }
    static func usage(_ message: String) -> Failure { Failure(code: 2, message: message) }
    static func unreachable(_ message: String) -> Failure { Failure(code: 3, message: message) }
}

// MARK: Commands

private struct Command {
    var name: String?
    var args: [String] = []
    var flags: Set<String> = []

    init(_ words: [String]) {
        let aliases = ["-y": "--yes", "-h": "--help", "-v": "--version"]
        for word in words {
            if word.hasPrefix("-"), word != "-" { flags.insert(aliases[word] ?? word) } else { args.append(word) }
        }
        if !args.isEmpty { name = args.removeFirst().lowercased() }
    }

    var json: Bool { flags.contains("--json") }
    /// Everything after the command, as one name ("openaccs use Work Max").
    var query: String { args.joined(separator: " ").trimmingCharacters(in: .whitespaces) }

    func run() throws {
        if flags.contains("--help") || name == "help" { return print(Self.help, terminator: "") }
        if flags.contains("--version") || name == "version" { return print("openaccs \(App.version)") }
        switch name {
        case nil, "status", "limits": try status()
        case "best": try best()
        case "use", "switch", "open": try use()
        case "launch": try launch()
        case "restart": try restart()
        case "refresh": try refresh()
        case "connect": try connect()
        case "add": try add()
        case "rename": try rename()
        case "remove": try remove()
        case "setup": try setup()
        case "vps", "server": try vps()
        default: throw Failure.usage("Unknown command “\(name ?? "")”. Run openaccs help.")
        }
    }

    func allow(_ allowed: Set<String>) throws {
        if let flag = flags.subtracting(allowed).sorted().first {
            throw Failure.usage("\(name ?? "status") doesn't take \(flag). Run openaccs help.")
        }
    }

    // MARK: One setup

    /// Scans and applies here, not in the app: scanning only reads, and every change checks its files first.
    func setup() throws {
        try allow(["--json", "--yes", "--dry-run"])
        let context = SetupService.context()
        let applier = SetupApplier(context: context)
        switch args.first {
        case nil:
            let reports = OneSetup.scan(context)
            if json { return try printJSON(reports.map(SetupSummary.init)) }
            for report in reports { print("\(report.area.title.padding(toLength: 14, withPad: " ", startingAt: 0)) \(report.summary)") }
            let attention = reports.attention
            if !attention.isEmpty {
                print("\nNeeds you")
                for item in attention { print("  \(item.level == .broken ? "✕" : "●") \(item.text)") }
            }
            let changes = reports.changes
            if !changes.isEmpty {
                print("\nChanges (openaccs setup apply [<id>…] [--dry-run])")
                for change in changes { print("  \(change.id)  \(change.title)") }
            }
        case "apply":
            let reports = OneSetup.scan(context)
            let ids = Set(args.dropFirst())
            let needed = reports.changes.includingRequirements(ids)
            let chosen = ids.isEmpty ? reports.recommendedChanges : reports.changes.filter { needed.contains($0.id) }
            if let unknown = ids.subtracting(reports.changes.map(\.id)).sorted().first {
                throw Failure.usage("No change “\(unknown)”. Run openaccs setup to list them.")
            }
            guard !chosen.isEmpty else { return print("Nothing to change.") }
            let chosenIDs = Set(chosen.map(\.id))
            if let conflict = reports.attention.first(where: { $0.fixes.count > 1 && chosenIDs.intersection($0.fixes).count > 1 }) {
                throw Failure.usage("Choose one option for: \(conflict.text)")
            }
            for change in chosen { print("  \(change.title)\(change.waitsFor == nil ? "" : " (skipped while its app is open)")") }
            if flags.contains("--dry-run") { return }
            try confirm("Apply \(chosen.count) change\(chosen.count == 1 ? "" : "s")?")
            let result = applier.apply(chosen)
            for entry in result.applied { print("Done: \(entry.title)") }
            for skipped in result.skipped { print("Not done: \(skipped.change.title), \(skipped.reason).") }
            if !result.skipped.isEmpty { throw Failure(code: 1, message: "") }
        case "history":
            let entries = applier.history().reversed()
            guard !entries.isEmpty else { return print("Nothing applied yet.") }
            for (n, entry) in entries.enumerated() {
                print("\(n + 1)  \(entry.date.formatted(date: .abbreviated, time: .shortened))  \(entry.title)\(entry.undoneAt == nil ? "" : "  (undone)")")
            }
        case "undo":
            // Undo has no preview, so a preview flag must never undo for real.
            if flags.contains("--dry-run") { throw Failure.usage("setup undo doesn't take --dry-run. Run openaccs help.") }
            let entries = Array(applier.history().reversed())
            guard args.count == 2, let n = Int(args[1]), entries.indices.contains(n - 1) else {
                throw Failure.usage("Undo which? openaccs setup undo <number from openaccs setup history>")
            }
            try confirm("Undo “\(entries[n - 1].title)”?")
            try applier.undo(entries[n - 1].id)
            print("Undone: \(entries[n - 1].title)")
        default:
            throw Failure.usage("openaccs setup [apply [<id>…] [--dry-run] | history | undo <n>] [--json]")
        }
    }

    /// `openaccs vps user@host`: this Mac's setup on a server, over the user's own ssh. Logins never travel: each
    /// tool signs in on the server itself.
    func vps() throws {
        try allow(["--yes", "--dry-run"])
        guard args.count == 1, let host = args.first, !host.hasPrefix("-") else {
            throw Failure.usage("openaccs vps user@host [--dry-run] [--yes]")
        }
        guard flags.contains("--dry-run") || Self.shell(["/usr/bin/ssh", "-o", "ConnectTimeout=15", host, "test \"$(id -u)\" != 0"]) == 0 else {
            throw Failure.error("Couldn't reach \(host) as a user other than root. Agents shouldn't run as root: create a user there (adduser) and use it.")
        }
        let paths = Paths.current
        let stage = paths.appSupport.appending(path: "Servers/\(host.replacingOccurrences(of: "/", with: "_"))/stage", directoryHint: .isDirectory)
        let plan = try ServerSetup.stage(SetupService.context(), into: stage)
        print("Goes to \(host):")
        for line in plan.goes { print("  \(line)") }
        print("Stays on this Mac:")
        for line in plan.stays { print("  \(line)") }
        if flags.contains("--dry-run") { return print("\nStaged in \(stage.path). Nothing was sent.") }
        try confirm("Set up \(host)?")
        guard let script = Bundle.main.url(forResource: "server-setup", withExtension: "sh") else {
            throw Failure.error("This OpenAccs has no server script. Reinstall it.")
        }
        let steps: [[String]] = [
            ["/usr/bin/ssh", host, "mkdir -p ~/.openaccs"],
            ["/usr/bin/rsync", "-a", "--delete", stage.path + "/", "\(host):.openaccs/incoming/"],
            ["/usr/bin/rsync", "-a", script.path, "\(host):.openaccs/setup.sh"],
            ["/usr/bin/ssh", "-t", host, "bash ~/.openaccs/setup.sh"],
        ]
        for step in steps where Self.shell(step) != 0 {
            throw Failure.error("Stopped: \(step.prefix(2).joined(separator: " ")) failed. What was replaced on \(host) is in ~/.openaccs/backups.")
        }
        // A command over ssh doesn't read the login profile, so it gets the PATH server-setup.sh installs into;
        // a claude or codex installed elsewhere is still found after it.
        let path = "PATH=$HOME/.local/bin:$HOME/.codex/bin:$PATH"
        let signIns = [("Claude Code", "\(path) claude auth login"), ("Codex", "\(path) codex login --device-auth")]
        if isatty(STDIN_FILENO) != 0 {
            print("\nEach tool signs in on \(host) itself (your logins on this Mac never travel).")
            for (tool, command) in signIns {
                FileHandle.standardError.write(Data("Sign \(tool) in on \(host) now? [Y/n] ".utf8))
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                if answer.isEmpty || answer == "y" || answer == "yes", Self.shell(["/usr/bin/ssh", "-t", host, command]) != 0 {
                    print("\(tool) didn't sign in. Try again: ssh -t \(host) '\(command)'")
                }
            }
        } else {
            print("\nSign in on \(host):")
            for (_, command) in signIns { print("  ssh -t \(host) '\(command)'") }
        }
        print("\nOn \(host):")
        _ = Self.shell(["/usr/bin/ssh", host, """
            export \(path); \
            printf '  Claude Code: '; claude auth status >/dev/null 2>&1 && echo signed in || echo not signed in; \
            printf '  Codex: '; codex login status >/dev/null 2>&1 && echo signed in || echo not signed in; \
            printf '  Codex reads: %s\\n' "$(readlink ~/.codex/AGENTS.md)"; \
            printf '  Skills: %s\\n' "$(ls ~/.agents/skills 2>/dev/null | wc -l | tr -d ' ')"
            """])
    }

    /// Runs a command with this terminal (so ssh can ask for a password or a host key); returns its exit status.
    static func shell(_ argv: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: argv[0])
        process.arguments = Array(argv.dropFirst())
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func printJSON<T: Encodable>(_ value: T) throws {
        print(String(decoding: try JSON.encoder.encode(value), as: UTF8.self))
    }

    // MARK: Reading

    func status() throws {
        try allow(["--json"])
        guard args.count <= 1 else { throw Failure.usage("status takes one provider at most: claude, codex, grok, kimi or zai.") }
        let only = try args.first.map(provider)
        show(try App.call(ControlRequest(.status)), only: only)
    }

    func refresh() throws {
        try allow(["--json"])
        guard args.isEmpty else { throw Failure.usage("refresh takes no arguments.") }
        Terminal.note("Refreshing…")
        show(try App.call(ControlRequest(.refresh)), only: nil)
    }

    func best() throws {
        try allow(["--json"])
        guard args.count == 1 else { throw Failure.usage("Best of which? openaccs best claude|codex|grok|kimi|zai") }
        let provider = try provider(args[0])
        let accounts = try App.call(ControlRequest(.status)).accounts
        let best = try Self.best(provider, in: accounts)
        if json { return print(ControlAccount.json(best)) }
        Terminal.out(StatusText(color: Terminal.color).render(best, number: Self.number(best, in: accounts)))
    }

    private func show(_ reply: ControlResponse, only: Provider?) {
        if json { return print(ControlAccount.json(reply.accounts.filter { only == nil || $0.provider == only })) }
        Terminal.out(StatusText(color: Terminal.color).render(reply.accounts, only: only, notice: reply.notice))
    }

    // MARK: Acting

    /// Resolve the whole selection before acting. Always ask the app, which checks live processes under
    /// its per-profile lock; a status snapshot in this client cannot prevent concurrent launches.
    func launch() throws {
        try allow(["--all", "--json"])
        guard flags.contains("--all") ? args.isEmpty : !args.isEmpty else {
            throw Failure.usage("openaccs launch <account>… | --all [--json]. Quote names containing spaces.")
        }
        let accounts = try App.call(ControlRequest(.status)).accounts
        let selection = flags.contains("--all") ? accounts.filter { $0.provider == .claude || $0.provider == .codex }
            : try args.map { try resolve($0, in: accounts) }
        guard selection.allSatisfy({ $0.provider == .claude || $0.provider == .codex }) else { throw Failure.usage("Only Claude and Codex have app windows to launch.") }
        var seen = Set<UUID>()
        var results: [ControlLaunchResult] = []
        for account in selection where seen.insert(account.id).inserted {
            let result: ControlLaunchResult
            do {
                guard let launched = try App.call(ControlRequest(.launch, id: account.id)).launch else {
                    throw Failure.error("This OpenAccs doesn't support launch yet. Update and reopen OpenAccs.")
                }
                result = launched
            } catch {
                let message = (error as? Failure)?.message ?? error.localizedDescription
                result = ControlLaunchResult(id: account.id, label: account.label, status: .failed, error: message)
            }
            results.append(result)
            if !json {
                switch result.status {
                case .opened: print("Opened \(result.label) (PID \(result.pid ?? 0)).")
                case .alreadyOpen: print("Already open: \(result.label) (PID \(result.pid ?? 0)).")
                case .failed: print("Failed: \(result.label): \(result.error ?? "Unknown error")")
                }
            }
        }
        if json { try printJSON(["results": results]) }
        if results.contains(where: { $0.status == .failed }) { throw Failure.error("") }
    }

    func use() throws {
        try allow(["--yes", "--best"])
        let accounts = try App.call(ControlRequest(.status)).accounts
        let account: ControlAccount
        if flags.contains("--best") {
            guard args.count == 1 else { throw Failure.usage("Use the best of which? openaccs use --best claude|codex|grok|kimi|zai") }
            account = try Self.best(try provider(args[0]), in: accounts)
        } else {
            account = try resolve(query, in: accounts)
        }
        switch account.provider {
        case .claude:
            Terminal.note("Opening \(account.label)…")
            _ = try App.call(ControlRequest(.open, id: account.id))
            print(account.state == .open ? "Switched to \(account.label)." : "Opened \(account.label).")
        case .codex:
            _ = try App.call(ControlRequest(.open, id: account.id))
            print("Opened Codex on \(account.label).")
        case .grok, .kimi, .zai:
            _ = try App.call(ControlRequest(.open, id: account.id))
            print("Opened the \(account.provider.displayName) usage page.")
        }
    }

    func restart() throws {
        try allow([])
        let account = try resolve(query, in: try App.call(ControlRequest(.status)).accounts, claudeOnly: "restart")
        Terminal.note("Restarting \(account.label)…")
        _ = try App.call(ControlRequest(.restart, id: account.id))
        print(account.state == .open ? "Restarted \(account.label)." : "Opened \(account.label).")
    }

    func connect() throws {
        try allow([])
        let account = try resolve(query, in: try App.call(ControlRequest(.status)).accounts, claudeOnly: "connect")
        let reply = try App.call(ControlRequest(.connect, id: account.id))
        show(reply, only: .claude)
    }

    func rename() throws {
        try allow([])
        guard args.count >= 2 else { throw Failure.usage("openaccs rename <account> <new name>") }
        let account = try resolve(args[0], in: try App.call(ControlRequest(.status)).accounts)
        let name = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        _ = try App.call(ControlRequest(.rename, id: account.id, name: name))
        print("Renamed \(account.label) to \(name).")
    }

    func remove() throws {
        try allow(["--yes"])
        let account = try resolve(query, in: try App.call(ControlRequest(.status)).accounts)
        try confirm("Remove \(account.label)? \(Self.removal(account))")
        _ = try App.call(ControlRequest(.remove, id: account.id))
        print("Removed \(account.label).")
    }

    func add() throws {
        try allow(["--china"])
        guard let word = args.first?.lowercased(), let kind = word == "z.ai" ? .zai : ControlRequest.Kind(rawValue: word) else {
            throw Failure.usage("Add what? openaccs add claude <name> | codex | grok | grok-bot | kimi | zai")
        }
        let rest = Array(args.dropFirst())
        if flags.contains("--china"), kind != .kimi, kind != .zai { throw Failure.usage("--china is for kimi and zai.") }
        var request = ControlRequest(.add, kind: kind)
        switch kind {
        case .claude:
            guard !rest.isEmpty else { throw Failure.usage("Name the new profile: openaccs add claude <name>") }
            request.name = rest.joined(separator: " ")
            Terminal.note("Opening a new Claude window…")
        case .codex, .grok:
            guard rest.isEmpty else { throw Failure.usage("add \(word) takes no arguments.") }
            Terminal.note("Sign in to \(kind == .codex ? "ChatGPT" : "Grok") in your browser. Ctrl-C cancels.")
        case .grokBot:
            guard rest.count <= 1 else { throw Failure.usage("openaccs add grok-bot [<bot account>]") }
            request.name = rest.first
        case .kimi, .zai:
            guard rest.count <= 1 else { throw Failure.usage("openaccs add \(word) [<key> | -] [--china]") }
            let product = kind == .kimi ? "Kimi Code" : "Z.ai"
            request.key = try Self.readKey(rest.first ?? "-", product: product, command: word)
            request.region = flags.contains("--china") ? "china" : "global"
            Terminal.note("Checking the key with \(product)…")
        }
        let before = Set(try App.call(ControlRequest(.status)).accounts.map(\.id))
        let after = try App.call(request).accounts
        let added = after.first { !before.contains($0.id) }
        switch kind {
        case .claude:
            print("""
            Added \(request.name ?? "the profile"). In the new Claude window choose Continue with email and type the code.
            Avoid Google sign-in while another Claude is open. Each profile also downloads ~12 GB for Cowork.
            """)
        default: print(added.map { "Added \($0.label)." } ?? "Signed in again.")
        }
    }

    // MARK: Helpers

    func provider(_ word: String) throws -> Provider {
        guard let provider = Provider(cliName: word) else {
            throw Failure.usage("Unknown provider “\(word)”. Use claude, codex, grok, kimi or zai.")
        }
        return provider
    }

    /// The account the user meant. Numbers and ids count over the whole list, as status shows it.
    func resolve(_ query: String, in accounts: [ControlAccount], claudeOnly verb: String? = nil) throws -> ControlAccount {
        guard !query.isEmpty else { throw Failure.usage("Which account? Give a name, provider:name or the number from openaccs status.") }
        let wholeList = query.allSatisfy(\.isNumber) || UUID(uuidString: query) != nil
        let pool = verb == nil || wholeList ? accounts : accounts.filter { $0.provider == .claude }
        var match = AccountMatch.find(query, in: pool)
        if match == .none, pool.count != accounts.count { match = AccountMatch.find(query, in: accounts) }   // to say why it can't
        switch match {
        case .found(let account):
            if let verb, account.provider != .claude {
                throw Failure.error("\(account.label) is a \(account.provider.displayName) account; only Claude profiles can \(verb).")
            }
            return account
        case .none:
            throw Failure.error("No \(verb == nil ? "" : "Claude ")account matches “\(query)”. Run openaccs status to see them.")
        case .ambiguous(let hits):
            let list = hits.map { "\(Self.number($0, in: accounts)) \($0.provider.rawValue):\($0.label)" }.joined(separator: ", ")
            throw Failure.error("“\(query)” matches \(hits.count) accounts: \(list). Use the number or provider:name.")
        }
    }

    /// Asks on a terminal; elsewhere only `--yes` goes ahead, so a script never changes accounts by accident.
    func confirm(_ question: String) throws {
        if flags.contains("--yes") { return }
        guard isatty(STDIN_FILENO) != 0 else { throw Failure.usage("\(question) Run again with --yes to confirm.") }
        FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard answer == "y" || answer == "yes" else { throw Failure.error("Nothing changed.") }
    }

    static func best(_ provider: Provider, in accounts: [ControlAccount]) throws -> ControlAccount {
        guard let best = ControlAccount.best(of: provider, in: accounts) else {
            let empty = accounts.contains { $0.provider == provider && !$0.needsSignIn && $0.room != nil }
            throw Failure.error(empty ? "Every \(provider.displayName) account is out, and none says when it's back."
                                      : "No \(provider.displayName) account has limits to compare yet.")
        }
        return best
    }

    static func number(_ account: ControlAccount, in accounts: [ControlAccount]) -> Int {
        (accounts.firstIndex { $0.id == account.id } ?? 0) + 1
    }

    /// What Remove really does, as the panel says it.
    static func removal(_ account: ControlAccount) -> String {
        switch account.provider {
        case .claude: "OpenAccs forgets it. The Claude profile and its history stay on disk."
        case .codex where account.state == .active: "OpenAccs stops showing it. Codex stays signed in."
        case .codex: "OpenAccs deletes its saved sign-in for this account. Adding it back needs a browser sign-in."
        case .grok, .kimi, .zai: "OpenAccs forgets this account and its saved key."
        }
    }

    /// The key from the argument, or with "-" from stdin: typed without echo on a terminal, piped otherwise.
    /// Either way it stays out of shell history.
    static func readKey(_ argument: String, product: String, command: String) throws -> String {
        var key = argument
        if argument == "-" {
            if isatty(STDIN_FILENO) != 0 {
                var buffer = [CChar](repeating: 0, count: 1024)
                defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
                guard readpassphrase("\(product) API key: ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
                    throw Failure.usage("No key given.")
                }
                key = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            } else {
                key = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            }
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure.usage("No key given. Pipe it in: pbpaste | openaccs add \(command) -") }
        return key
    }

    static let help = """
    openaccs: every AI account, from the terminal.

      openaccs [status] [provider] [--json]   what's left on every account, and when it comes back
      openaccs best <provider> [--json]       the account with the most left
      openaccs use <account> [--yes]          show or open its window · others: usage page
      openaccs use --best <provider> [--yes]  the same, for the account with the most left
      openaccs launch <account>… [--json]    open saved Claude and Codex profiles; skip those already open
      openaccs launch --all [--json]         the same, for every saved Claude and Codex profile
      openaccs restart <account>              restart a Claude profile so it loads new sessions
      openaccs refresh [--json]               ask every provider now, then show status
      openaccs connect <account>              refresh Claude limits (legacy alias)
      openaccs add claude <name>
      openaccs add codex | grok | grok-bot [<bot account>]
      openaccs add kimi | zai [<key> | -] [--china]
                                              no key or "-" reads it from stdin, out of shell history
      openaccs rename <account> <new name>
      openaccs remove <account> [--yes]
      openaccs setup [--json]                 what Claude and Codex share, what needs you, what would change
      openaccs setup apply [<id>…] [--dry-run] [--yes]
                                              apply the recommended (or the named) changes; undo from history
      openaccs setup history | undo <n>
      openaccs vps user@host [--dry-run]      this Mac's setup on a server (each tool signs in there itself)
      openaccs help | version

    <account>   a name or a unique part of it, provider:name, or the number status shows
    <provider>  claude, codex, grok, kimi, zai
    aliases     limits = status · switch, open = use
    exit codes  0 ok · 1 error · 2 usage · 3 OpenAccs not reachable

    """
}

// MARK: The app

private enum App {
    static var socket: URL { Paths.current.controlSocket }

    /// Sends one request, starting OpenAccs in the background first when it isn't running.
    static func call(_ request: ControlRequest) throws -> ControlResponse {
        let reply: ControlResponse
        do {
            reply = try ControlClient.send(request, to: socket)
        } catch ControlError.unreachable {
            try launch()
            reply = try ControlClient.send(request, to: socket)
        } catch ControlError.connectionLost {
            throw Failure.error("OpenAccs stopped before answering. Did it quit?")
        }
        if let error = reply.error { throw Failure.error(error) }
        return reply
    }

    /// Opens the app this executable belongs to without bringing it forward, then waits up to 15 s for it.
    static func launch() throws {
        guard let app = bundle else { throw Failure.unreachable("OpenAccs isn't running, and this copy isn't inside OpenAccs.app.") }
        Terminal.note("Starting OpenAccs…")
        var arguments = ["-g"]
        if Paths.isOverridden { arguments += ["--env", "OPENACCS_HOME=\(Paths.current.home.path)"] }
        let open = Process()
        open.executableURL = URL(filePath: "/usr/bin/open")
        open.arguments = arguments + [app.path]
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            throw Failure.unreachable("Couldn't start OpenAccs: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if ControlClient.isAnswering(socket) { return }
            usleep(150_000)
        }
        throw Failure.unreachable("OpenAccs didn't answer within 15 seconds. If it's open, quit and reopen it.")
    }

    /// The real executable (the ~/.local/bin link resolved by the kernel), so the right app is found and started.
    static var executable: URL? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(filePath: buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    /// …/OpenAccs.app for …/OpenAccs.app/Contents/MacOS/OpenAccs.
    static var bundle: URL? {
        guard let app = executable?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
              app.pathExtension == "app" else { return nil }
        return app
    }

    static var version: String {
        let info = bundle.flatMap { Bundle(url: $0)?.infoDictionary } ?? [:]
        return info["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

// MARK: Terminal

private enum Terminal {
    /// ANSI color only for a person at a terminal, and never with NO_COLOR.
    static var color: Bool {
        isatty(STDOUT_FILENO) != 0 && (ProcessInfo.processInfo.environment["NO_COLOR"] ?? "").isEmpty
    }

    static func out(_ text: String) { print(text, terminator: "") }

    /// Progress for a person watching; scripts don't get it.
    static func note(_ text: String) {
        if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    }

    static func error(_ text: String) { FileHandle.standardError.write(Data("openaccs: \(text)\n".utf8)) }
}

extension Paths {
    /// This Mac's home. Debug builds can be pointed at a throwaway one with OPENACCS_HOME (end-to-end tests of
    /// the app and `openaccs` without touching real accounts: its own Keychain items and preferences, and Codex
    /// never switches, since that quits the real ChatGPT app). Release builds ignore the variable.
    static let current: Paths = override.map { Paths(home: $0) } ?? Paths()

    static var isOverridden: Bool { override != nil }

    private static var override: URL? {
        #if DEBUG
        if let home = ProcessInfo.processInfo.environment["OPENACCS_HOME"], !home.isEmpty {
            return URL(filePath: home, directoryHint: .isDirectory)
        }
        #endif
        return nil
    }
}
