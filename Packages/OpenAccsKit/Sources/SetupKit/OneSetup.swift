import Foundation

/// Every area, scanned (read only).
public enum OneSetup {
    public static func scan(_ context: SetupContext) -> [AreaReport] {
        let imports = ImportSyncSetup.scan(context)
        let removals = Set(imports.changes.flatMap(\.operations).compactMap { operation -> String? in
            if case .remove(let path, _) = operation { return path }
            return nil
        })
        var skills = SkillsSetup.scan(context, excluding: removals)
        for i in skills.changes.indices where skills.changes[i].operations.contains(where: {
            if case .move(_, let destination, _) = $0 { return removals.contains(destination) }
            return false
        }) {
            skills.changes[i].requires.append("importSync.remove-copies")
        }
        return [
            InstructionsSetup.scan(context),
            skills,
            MCPSetup.scan(context),
            ClaudeAppSetup.scan(context),
            DefaultsSetup.scan(context),
            imports,
        ]
    }
}

public extension [SetupChange] {
    func includingRequirements(_ ids: Set<String>) -> Set<String> {
        var selected = ids
        while true {
            let next = selected.union(filter { selected.contains($0.id) }.flatMap(\.requires))
            if next == selected { return selected }
            selected = next
        }
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
