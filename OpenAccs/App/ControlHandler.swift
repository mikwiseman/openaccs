import Foundation
import OpenAccsCore

/// The running app's side of `openaccs`: answers the control socket with the same AppModel actions as the
/// panel, so a command behaves exactly like the click it stands for.
@MainActor
final class ControlHandler {
    private static var server: ControlServer?

    /// At launch (never in snapshot mode): put `openaccs` on the PATH and start answering.
    static func start(model: AppModel) {
        guard server == nil else { return }
        let paths = Paths.current
        CommandLink.install(in: paths)
        let handler = ControlHandler(model: model)
        let server = ControlServer(socket: paths.controlSocket) { request in await handler.handle(request) }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("OpenAccs: openaccs commands won't work this run: %@", error.localizedDescription)
        }
    }

    private let model: AppModel

    private init(model: AppModel) { self.model = model }

    func handle(_ request: ControlRequest) async -> ControlResponse {
        // Right after launch the accounts are still loading, and every command needs them.
        for _ in 0..<300 where !model.isReady { try? await Task.sleep(for: .milliseconds(100)) }
        do {
            try await perform(request)
            return answer(nil)
        } catch is CancellationError {
            return answer("Cancelled.")
        } catch {
            return answer(error.localizedDescription)
        }
    }

    private func answer(_ error: String?) -> ControlResponse {
        ControlResponse(error: error, accounts: ControlAccount.inDisplayOrder(model.rows.map(Self.account)), notice: model.notice)
    }

    private func perform(_ request: ControlRequest) async throws {
        let model = self.model
        switch request.command {
        case .status:
            return
        case .refresh:
            await model.refreshNow()
        case .open:
            let id = try row(request.id).id
            try await toTheEnd { try await model.open(id) }
        case .restart:
            let id = try row(request.id, claudeOnly: "restart").id
            try await toTheEnd { try await model.restart(id) }
        case .connect:
            // A browser sign-in: Ctrl-C in the terminal cancels it, like Cancel in the panel. The model refuses
            // a window whose account it doesn't know yet, one with live limits, and a second sign-in at once.
            let row = try row(request.id, claudeOnly: "connect")
            try await model.connectExactLimits(row.id)
        case .rename:
            let name = request.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { throw Failure("The new name is empty.") }
            model.rename(try row(request.id).id, to: name)
        case .remove:
            model.remove(try row(request.id).id)
        case .add:
            try await add(request)
        }
    }

    private func add(_ request: ControlRequest) async throws {
        let model = self.model
        let key = request.key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let region = request.region == "china" ? "china" : "global"
        switch request.kind {
        case .claude:
            let name = request.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try await toTheEnd { try await model.addClaude(label: name) }
        case .codex:
            try await model.addCodex()
        case .grok:
            try await model.addGrokCLI()
        case .grokBot:
            try await model.addGrokBot(account: grokBot(request.name))
        case .kimi:
            guard !key.isEmpty else { throw Failure("No key given.") }
            try await model.addKimi(key: key, region: region)
        case .zai:
            guard !key.isEmpty else { throw Failure("No key given.") }
            try await model.addZai(key: key, region: region)
        case nil:
            throw Failure("Add what? claude, codex, grok, grok-bot, kimi or zai.")
        }
    }

    /// The Grok Bot sign-in to add: the one named, or the only one on this Mac not added yet.
    private func grokBot(_ name: String?) throws -> String {
        let found = model.grokBotAccounts
        if let name, !name.isEmpty {
            guard found.contains(name) else {
                throw Failure(found.isEmpty ? "No Grok Bot sign-in to add on this Mac." : "Grok Bot has no sign-in “\(name)”. Found: \(found.joined(separator: ", ")).")
            }
            return name
        }
        switch found.count {
        case 0: throw Failure("No Grok Bot sign-in to add on this Mac (or it's added already).")
        case 1: return found[0]
        default: throw Failure("Grok Bot has several sign-ins. Name one: \(found.joined(separator: ", ")).")
        }
    }

    /// Runs to the end even if the terminal goes away: a half-done Codex switch or Claude restart is
    /// worse than either outcome.
    private func toTheEnd(_ body: @escaping @MainActor () async throws -> Void) async throws {
        try await Task { try await body() }.value
    }

    private func row(_ id: UUID?, claudeOnly verb: String? = nil) throws -> PanelRow {
        guard let row = model.rows.first(where: { $0.id == id }) else {
            throw Failure("That account isn't in OpenAccs anymore. Run openaccs status.")
        }
        if let verb, row.provider != .claude { throw Failure("\(row.label) isn't a Claude profile; only those can \(verb).") }
        return row
    }

    static func account(_ row: PanelRow) -> ControlAccount {
        let state: ControlAccount.State = switch row.state {
        case .running: .open
        case .active: .active
        case .idle: .idle
        }
        return ControlAccount(id: row.id, provider: row.provider, label: row.label, plan: row.plan, state: state,
                              usage: row.usage, error: row.error, needsSignIn: row.needsSignIn,
                              pendingSessions: row.pendingSessions, pendingChanges: row.pendingChanges, best: row.isBest)
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// `~/.local/bin/openaccs` → this app's executable, so `openaccs` works in any terminal with ~/.local/bin on
/// its PATH (Claude Code's installer puts it there). Only creates the link, or repoints one that already
/// points into an OpenAccs.app; anything else at that path is never touched.
enum CommandLink {
    static func install(in paths: Paths) {
        #if DEBUG
        // Development builds leave the real ~/.local/bin alone; with OPENACCS_HOME they use the test home's.
        guard Paths.isOverridden else { return }
        #endif
        guard let executable = Bundle.main.executableURL, isLasting(executable) else { return }
        let bin = paths.home.appending(path: ".local/bin", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bin.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        let link = bin.appending(path: "openaccs")
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            guard target != executable.path, target.split(separator: "/").contains("OpenAccs.app") else { return }
        } else {
            var info = stat()
            guard lstat(link.path, &info) != 0, errno == ENOENT else { return }
        }
        // Made next to it, then renamed over it: the command is never missing, even for a moment.
        let temp = bin.appending(path: ".openaccs-\(UUID().uuidString)")
        guard symlink(executable.path, temp.path) == 0 else { return }
        if rename(temp.path, link.path) != 0 { unlink(temp.path) }
    }

    /// Not a translocated copy or a disk image: a link there would break as soon as the app moves.
    private static func isLasting(_ executable: URL) -> Bool {
        if executable.path.contains("/AppTranslocation/") { return false }
        return (try? executable.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly != true
    }
}
