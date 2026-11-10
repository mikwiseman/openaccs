import Foundation

public enum PanelSection: String, CaseIterable, Codable, Sendable {
    case claude, codex, limits

    public init(_ provider: Provider) {
        switch provider {
        case .claude: self = .claude
        case .codex: self = .codex
        case .grok, .kimi, .zai: self = .limits
        }
    }

    public var title: String { rawValue.capitalized }
}

/// A display preference, separate from account discovery, usage ranking and profile selection.
public struct PanelOrder: Codable, Equatable, Sendable {
    private var sections = PanelSection.allCases
    private var accounts: [PanelSection: [UUID]] = [:]

    public init() {}

    public func groups<Row: Identifiable>(_ rows: [Row], provider: KeyPath<Row, Provider>)
        -> [(section: PanelSection, rows: [Row])] where Row.ID == UUID {
        let bySection = Dictionary(grouping: rows) { PanelSection($0[keyPath: provider]) }
        return sections.compactMap { section in
            guard let members = bySection[section] else { return nil }
            guard let ids = accounts[section] else { return (section, members) }
            let ranks = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
            // Stable sort: new accounts follow the arranged ones, in discovery order.
            return (section, members.sorted { ranks[$0.id, default: .max] < ranks[$1.id, default: .max] })
        }
    }

    public mutating func moveSection(_ section: PanelSection, before next: PanelSection?) {
        if let moved = Self.moving(section, before: next, in: sections) { sections = moved }
    }

    public mutating func moveAccount(_ id: UUID, before next: UUID?, in section: PanelSection, siblings: [UUID]) {
        if let moved = Self.moving(id, before: next, in: siblings) { accounts[section] = moved }
    }

    /// A nil anchor is the end of this group. Ignore stale or foreign drag targets.
    private static func moving<T: Equatable>(_ item: T, before next: T?, in items: [T]) -> [T]? {
        guard item != next, let source = items.firstIndex(of: item) else { return nil }
        var result = items
        result.remove(at: source)
        if let next {
            guard let destination = result.firstIndex(of: next) else { return nil }
            result.insert(item, at: destination)
        } else {
            result.append(item)
        }
        return result == items ? nil : result
    }
}
