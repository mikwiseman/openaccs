import Foundation
import OpenAccsCore

/// The account and org whose limits a Claude window shows, lowercased. One Claude Code sign-in serves them.
public struct ClaudeAccountKey: Sendable, Hashable, CustomStringConvertible {
    public let account: String
    public let org: String

    /// nil unless both are known and safe as folder names, as in Claude's card folders.
    public init?(account: String?, org: String?) {
        guard let account, let org, FS.isSafeName(account), FS.isSafeName(org) else { return nil }
        self.account = account.lowercased()
        self.org = org.lowercased()
    }

    /// `<account>/<org>`, as in Claude's card folders.
    public var description: String { "\(account)/\(org)" }
}

extension ClaudeProfile {
    /// The account and org whose live limits this window shows: the folder Claude's log names, or the
    /// account the window was added with, found through its own card folder. nil for a guess at another
    /// account's newest card or at one of the account's orgs, and while the org is unknown.
    public func limitsAccount(addedAs stored: String?) -> ClaudeAccountKey? {
        guard isConfirmed || (!orgIsGuess && stored != nil && accountUuid?.lowercased() == stored?.lowercased()) else { return nil }
        return ClaudeAccountKey(account: accountUuid, org: orgUuid)
    }
}

/// What a Claude row shows: Claude Code's live numbers, or one line saying why there are none.
public enum ClaudeLimits {
    /// How long a Claude Code answer counts as live. It is asked every 5 minutes.
    public static let liveFor: TimeInterval = 30 * 60
    public static let unknownAccount = "Open this window once to connect live limits"
    /// The same, for a window that is open: it is still at Claude's sign-in.
    public static let signInFirst = "Sign in to Claude in this window to connect live limits"
    public static let notConnected = "No live limits"
    public static let signedOut = "Limits signed out"

    public struct Row: Equatable, Sendable {
        /// Live numbers, or nil.
        public var usage: UsageSnapshot?
        /// Why there are none. nil when there's nothing to say.
        public var note: String?
        /// The row offers Connect, because a new sign-in may fix it.
        public var connect: Bool

        public init(usage: UsageSnapshot?, note: String?, connect: Bool) {
            self.usage = usage
            self.note = note
            self.connect = connect
        }
    }

    /// `account`: OpenAccs knows the window's account and org. `signIn`: a stored folder is signed in to them.
    /// `answer` and `problem`: that folder's last Claude Code answer, and the failure of the last ask after it.
    public static func row(account: Bool, signIn: Bool, answer: UsageSnapshot?, problem: UsageError?, now: Date) -> Row {
        guard account else { return Row(usage: nil, note: unknownAccount, connect: false) }
        guard signIn else { return Row(usage: nil, note: notConnected, connect: true) }
        // Signed out ends the numbers at once; one failed ask doesn't.
        if problem == .needsSignIn { return Row(usage: nil, note: signedOut, connect: true) }
        if let answer, now.timeIntervalSince(answer.asOf) < liveFor { return Row(usage: answer, note: nil, connect: false) }
        switch problem {
        case .unexpected(let message)?: return Row(usage: nil, note: message, connect: true)
        case nil: return Row(usage: nil, note: nil, connect: false)  // asked again in a moment
        default: return Row(usage: nil, note: notConnected, connect: true)
        }
    }
}
