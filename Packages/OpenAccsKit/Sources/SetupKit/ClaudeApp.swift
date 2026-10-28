import Foundation
import OpenAccsCore

/// What other areas need around the Claude app's windows. The app's own settings are no area of One setup:
/// OpenAccs's Claude sync keeps them the same in every window on its own (ClaudeKit `AppSettings`).
public enum ClaudeAppSetup {
    /// The profile's name in OpenAccs, else its folder's name.
    static func name(of ref: ClaudeProfileRef, in accounts: [Account], context: SetupContext) -> String {
        let account = accounts.first { account in
            guard account.provider == .claude else { return false }
            let dir = account.claude?.dataDir.map { URL(filePath: $0) } ?? context.paths.claudeDefaultDataDir
            return dir.standardizedFileURL.path == ref.dataDir.path
        }
        return account?.label ?? ref.dataDir.lastPathComponent
    }

    /// Sorted, two-space indented JSON. Every value the app wrote stays the same; only the layout changes.
    static func serialize(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
