import Foundation
import OpenAccsCore

/// Non-secret identity returned by Claude's account endpoint for one membership of the current login.
public struct ClaudeMembership: Sendable, Hashable {
    public let key: ClaudeAccountKey
    public let organizationName: String
    public let email: String?
    public let plan: String?

    public var accountUuid: String { key.account }
    public var organizationUuid: String { key.org }

    /// The installed Claude desktop reads `/api/account.memberships[].organization` with these fields.
    /// Reject incomplete identity instead of importing a row that cannot select the right quota.
    static func parse(_ owner: [String: Any], account: String) throws -> [ClaudeMembership] {
        guard (owner["uuid"] as? String)?.lowercased() == account.lowercased() else {
            throw UsageError.unexpected("Claude is signed in to another account")
        }
        guard let memberships = owner["memberships"] as? [[String: Any]] else {
            throw UsageError.unexpected("Claude did not return its memberships")
        }
        var seen = Set<ClaudeAccountKey>()
        return try memberships.compactMap { membership in
            guard let organization = membership["organization"] as? [String: Any],
                  let key = ClaudeAccountKey(account: account, org: organization["uuid"] as? String) else {
                throw UsageError.unexpected("Claude returned a membership without a valid identity")
            }
            guard seen.insert(key).inserted else { return nil }
            let name = (organization["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let explicitPlan = (organization["plan_display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let plan: String? = if let explicitPlan, !explicitPlan.isEmpty { explicitPlan } else {
                switch organization["organization_type"] as? String {
                case "claude_max": "Max"
                case "claude_pro": "Pro"
                case "claude_team": "Team"
                case "claude_enterprise": "Enterprise"
                default: nil
                }
            }
            return ClaudeMembership(key: key, organizationName: name.flatMap { $0.isEmpty ? nil : $0 } ?? key.org,
                                    email: owner["email_address"] as? String, plan: plan)
        }
    }
}

extension ClaudeProfile {
    /// Persist only identity actually observed in the desktop log.
    public func recordIdentity(in info: inout ClaudeAccountInfo, knownMemberships: Set<ClaudeAccountKey> = []) {
        guard isConfirmed, info.organizationUuid == nil,
              let key = ClaudeAccountKey(account: accountUuid, org: orgUuid),
              !knownMemberships.contains(key),
              info.accountUuid == nil || info.accountUuid?.lowercased() == key.account else { return }
        info.accountUuid = key.account
        info.organizationUuid = key.org
    }

    /// Requested quota identity is separate from the organization currently selected in the window.
    /// A different or unknown observed login cannot supply a pinned membership's quota.
    public func limitsAccount(addedAs info: ClaudeAccountInfo) -> ClaudeAccountKey? {
        if let stored = info.accountUuid, accountUuid?.lowercased() != stored.lowercased() { return nil }
        guard let organization = info.organizationUuid else { return limitsAccount(addedAs: info.accountUuid) }
        guard let stored = info.accountUuid, accountUuid?.lowercased() == stored.lowercased() else { return nil }
        return ClaudeAccountKey(account: stored, org: organization)
    }

    /// Exact selection proof for routing to a membership; an inferred card folder is insufficient.
    public func requestedMembershipIsSelected(_ info: ClaudeAccountInfo) -> Bool {
        guard isConfirmed, let expected = limitsAccount(addedAs: info),
              let observed = ClaudeAccountKey(account: accountUuid, org: orgUuid) else { return false }
        return expected == observed
    }
}

extension ClaudeProfiles {
    /// Import memberships of one authorized desktop login without changing its selection.
    public func mergeMemberships(_ memberships: [ClaudeMembership], source: ClaudeAccountInfo,
                                 profile: ClaudeProfile, accounts: inout [Account], colorCount: Int) throws {
        if let expected = source.accountUuid, let observed = profile.accountUuid, observed.lowercased() != expected.lowercased() {
            throw UsageError.unexpected("Claude is signed in to another account")
        }
        if accounts.contains(where: {
            guard let info = $0.claude, info.organizationUuid == nil else { return false }
            return resolve(info).dataDir.standardizedFileURL.path == profile.dataDir.standardizedFileURL.path
        }) {
            guard profile.isConfirmed, let selected = ClaudeAccountKey(account: profile.accountUuid, org: profile.orgUuid),
                  memberships.contains(where: { $0.key == selected }) else {
                throw UsageError.unexpected("Select a membership in Claude, then discover again")
            }
        }
        for membership in memberships {
            let existing = accounts.firstIndex {
                guard let info = $0.claude else { return false }
                return info.accountUuid?.lowercased() == membership.accountUuid.lowercased()
                    && info.organizationUuid?.lowercased() == membership.organizationUuid.lowercased()
            }
            let unpinned = accounts.firstIndex {
                guard profile.isConfirmed, let info = $0.claude, info.organizationUuid == nil,
                      info.accountUuid == nil || info.accountUuid?.lowercased() == membership.accountUuid.lowercased() else { return false }
                return resolve(info).dataDir.standardizedFileURL.path == profile.dataDir.standardizedFileURL.path
                    && profile.orgUuid?.lowercased() == membership.organizationUuid.lowercased()
            }
            let info = ClaudeAccountInfo(dataDir: source.dataDir, legacyConfigDir: source.legacyConfigDir,
                accountUuid: membership.accountUuid,
                organizationUuid: membership.organizationUuid, organizationName: membership.organizationName,
                email: membership.email, plan: membership.plan)
            if let i = existing ?? unpinned {
                accounts[i].claude?.accountUuid = info.accountUuid
                accounts[i].claude?.organizationUuid = info.organizationUuid
                accounts[i].claude?.organizationName = info.organizationName
                accounts[i].claude?.email = info.email
                accounts[i].claude?.plan = info.plan
            } else {
                let used = Set(accounts.map(\.color))
                let color = (0..<colorCount).first { !used.contains($0) } ?? accounts.count % colorCount
                let label = membership.plan == "Max" ? "Personal Max" : membership.organizationName
                let account = Account(provider: .claude, label: label, color: color, claude: info)
                accounts.insert(account, at: (accounts.lastIndex { $0.provider == .claude }).map { $0 + 1 } ?? 0)
            }
        }
    }
}
