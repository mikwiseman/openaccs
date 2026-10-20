import Foundation
import OpenAccsCore

/// Codex's `auth.json`: `{auth_mode, OPENAI_API_KEY, tokens:{id_token, access_token, refresh_token, account_id}, last_refresh}`.
/// OpenAccs keeps the bytes opaque and reads only what it needs.
public enum CodexAuthFile {
    /// Who a ChatGPT sign-in belongs to: `tokens.account_id` (the workspace) plus the id_token claims.
    /// nil for API-key sign-ins, unreadable files, and mixed files whose `account_id` disagrees with the id_token.
    public static func identity(of authJSON: Data) -> CodexAccountInfo? {
        guard let tokens = JSON.object(authJSON)?["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let claims = JWT.claims(idToken)
        else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let profile = claims["https://api.openai.com/profile"] as? [String: Any] ?? [:]
        let claimedAccount = text(auth["chatgpt_account_id"])
        guard let userId = text(auth["chatgpt_user_id"]) ?? text(auth["user_id"]) ?? text(claims["sub"]),
              let accountId = text(tokens["account_id"]) ?? claimedAccount,
              claimedAccount == nil || claimedAccount == accountId
        else { return nil }
        return CodexAccountInfo(
            userId: userId, accountId: accountId,
            email: text(claims["email"]) ?? text(profile["email"]),
            plan: text(auth["chatgpt_plan_type"])
        )
    }

    static func accessToken(of authJSON: Data) -> String? { token("access_token", in: authJSON) }
    static func refreshToken(of authJSON: Data) -> String? { token("refresh_token", in: authJSON) }

    /// The file with the tokens from a refresh answer merged in and `last_refresh` set. Every other field is kept.
    static func merging(_ authJSON: Data, refreshed answer: [String: Any], at now: Date) -> Data? {
        guard var root = JSON.object(authJSON), var tokens = root["tokens"] as? [String: Any] else { return nil }
        for key in ["id_token", "access_token", "refresh_token"] {
            if let value = text(answer[key]) { tokens[key] = value }
        }
        root["tokens"] = tokens
        root["last_refresh"] = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now)
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func token(_ key: String, in authJSON: Data) -> String? {
        text((JSON.object(authJSON)?["tokens"] as? [String: Any])?[key])
    }
}

extension CodexAccountInfo {
    /// Keychain key of this login's auth.json snapshot.
    var vaultKey: String { "codex:\(userId):\(accountId)" }

    /// Same person in the same workspace (email and plan may change).
    func isSameLogin(as other: CodexAccountInfo) -> Bool {
        userId == other.userId && accountId == other.accountId
    }
}

/// A non-empty string, or nil.
func text(_ value: Any?) -> String? {
    guard let s = value as? String, !s.isEmpty else { return nil }
    return s
}
