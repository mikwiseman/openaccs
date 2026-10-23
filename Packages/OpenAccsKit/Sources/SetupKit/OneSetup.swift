import Foundation

/// Every area, scanned (read only).
public enum OneSetup {
    public static func scan(_ context: SetupContext) -> [AreaReport] {
        [
            InstructionsSetup.scan(context),
            SkillsSetup.scan(context),
            ClaudeAppSetup.scan(context),
        ]
    }
}

public extension [AreaReport] {
    var changes: [SetupChange] { flatMap(\.changes) }
    var attention: [Attention] { flatMap(\.attention) }

    /// Every change, except those that are one of several choices for the same thing: the user picks those.
    var recommendedChanges: [SetupChange] {
        let choices = Set(attention.filter { $0.fixes.count > 1 }.flatMap(\.fixes))
        return changes.filter { !choices.contains($0.id) }
    }
}
