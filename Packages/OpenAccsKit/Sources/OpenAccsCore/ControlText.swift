import Foundation

// MARK: Accounts as the CLI sees them

/// One account in `openaccs status --json` and on the control socket. Remaining is what matters:
/// `leftPercent` = 100 − `usedPercent`.
public struct ControlAccount: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable {
        /// Claude: the profile's app is open.
        case open
        /// Codex: the account in `~/.codex/auth.json`. Limits: connected.
        case active
        case idle
    }

    public struct Window: Codable, Sendable, Hashable {
        public var kind: UsageWindow.Kind
        /// Model- or feature-scoped windows ("Opus", "MCP"). nil for the main ones.
        public var label: String?
        public var leftPercent: Double
        public var usedPercent: Double
        public var resetsAt: Date?

        public init(_ window: UsageWindow) {
            kind = window.kind
            label = window.label
            usedPercent = window.usedPercent
            leftPercent = 100 - window.usedPercent
            resetsAt = window.resetsAt
        }
    }

    public var id: UUID
    public var provider: Provider
    public var label: String
    public var plan: String?
    public var state: State
    public var windows: [Window]
    public var credits: Credits?
    public var resetsAvailable: Int?
    /// When the provider measured these numbers.
    public var asOf: Date?
    public var source: String?
    /// Why usage is missing or may be wrong. nil when fine.
    public var error: String?
    public var needsSignIn: Bool
    /// Claude: sessions from other profiles this open profile hasn't loaded yet.
    public var pendingSessions: Int
    /// ✦ in the panel: the most left among this provider's accounts.
    public var best: Bool

    public init(
        id: UUID, provider: Provider, label: String, plan: String? = nil, state: State, usage: UsageSnapshot? = nil,
        error: String? = nil, needsSignIn: Bool = false, pendingSessions: Int = 0, best: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.plan = plan
        self.state = state
        windows = usage?.windows.map(Window.init) ?? []
        credits = usage?.credits
        resetsAvailable = usage?.resetsAvailable
        asOf = usage?.asOf
        source = usage?.source
        self.error = error
        self.needsSignIn = needsSignIn
        self.pendingSessions = pendingSessions
        self.best = best
    }

    /// The main windows worth showing, shortest first (as the panel's meters).
    public var mainWindows: [Window] {
        [UsageWindow.Kind.fiveHour, .weekly, .monthly].compactMap { kind in windows.first { $0.kind == kind && $0.label == nil } }
    }

    /// Room left in the tightest main window. nil without numbers.
    public var roomLeft: Double? { room?.left }

    public var room: Room? {
        Room(windows.filter { $0.label == nil }.map { ($0.leftPercent, $0.resetsAt) })
    }

    /// The best of `provider`'s working accounts (signed in, with numbers), by the same rule as the panel's ✦.
    public static func best(of provider: Provider, in accounts: [ControlAccount]) -> ControlAccount? {
        Room.best(accounts.filter { $0.provider == provider && !$0.needsSignIn }.compactMap { a in a.room.map { (a, $0) } })
    }

    /// Panel order: Claude, Codex, then Limits (Grok, Kimi, Z.ai as added). Row numbers follow it.
    public static func inDisplayOrder(_ accounts: [ControlAccount]) -> [ControlAccount] {
        PanelSection.allCases.flatMap { section in accounts.filter { section.includes($0.provider) } }
    }

    /// `openaccs status --json`: `{"accounts": [...]}`, sorted keys, ISO-8601 dates.
    public static func json(_ accounts: [ControlAccount]) -> String {
        render(["accounts": accounts])
    }

    /// `openaccs best --json`: one account object.
    public static func json(_ account: ControlAccount) -> String {
        render(account)
    }

    private static func render(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
    }
}

extension UsageSnapshot {
    /// Room left in the tightest main window (100 − the highest used %). nil without main windows.
    public var roomLeft: Double? { room?.left }

    public var room: Room? {
        Room(windows.filter { $0.label == nil }.map { (100 - $0.usedPercent, $0.resetsAt) })
    }
}

/// What an account has to give now, for the panel's ✦ and `openaccs best`.
public struct Room: Sendable, Equatable {
    /// Percent left in the tightest main window.
    public var left: Double
    /// With nothing left: when every empty window has refilled. nil = unknown or not empty.
    public var backAt: Date?

    /// From the main windows' (percent left, reset). nil without any.
    init?(_ windows: [(left: Double, resetsAt: Date?)]) {
        guard let left = windows.map(\.left).min() else { return nil }
        self.left = left
        let empty = windows.filter { $0.left <= 0 }
        let resets = empty.compactMap(\.resetsAt)
        backAt = !empty.isEmpty && resets.count == empty.count ? resets.max() : nil
    }

    /// The most left wins; with nothing left anywhere, the one back soonest. Ties go to the first.
    public static func best<T>(_ scored: [(T, Room)]) -> T? {
        scored.reduce(nil as (T, Room)?) { best, next in
            guard let best else { return next }
            return next.1.beats(best.1) ? next : best
        }?.0
    }

    private func beats(_ other: Room) -> Bool {
        if left != other.left { return left > other.left }
        return left <= 0 && (backAt ?? .distantFuture) < (other.backAt ?? .distantFuture)
    }
}

extension Provider {
    /// The provider a user typed: "claude", "codex", "grok", "kimi", "zai" or "z.ai" (any case).
    public init?(cliName: String) {
        let name = cliName.lowercased()
        if name == "z.ai" { self = .zai; return }
        self.init(rawValue: name)
    }
}

/// The panel's sections.
enum PanelSection: CaseIterable {
    case claude, codex, limits

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .limits: "Limits"
        }
    }

    func includes(_ provider: Provider) -> Bool {
        switch self {
        case .claude: provider == .claude
        case .codex: provider == .codex
        case .limits: provider != .claude && provider != .codex
        }
    }
}

// MARK: Finding an account by what the user typed

public enum AccountMatch: Equatable, Sendable {
    case found(ControlAccount)
    case none
    case ambiguous([ControlAccount])

    /// Matches, in order: the id, the row number (position + 1), "provider:name", then the name exactly
    /// (any case), a unique prefix, a unique substring. Several exact matches are ambiguous, never guessed.
    public static func find(_ query: String, in accounts: [ControlAccount]) -> AccountMatch {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return .none }
        if let id = UUID(uuidString: query), let account = accounts.first(where: { $0.id == id }) { return .found(account) }
        if query.allSatisfy(\.isNumber), let n = Int(query) {
            return accounts.indices.contains(n - 1) ? .found(accounts[n - 1]) : .none
        }
        var candidates = accounts
        var name = query
        if let colon = query.firstIndex(of: ":"), let provider = Provider(cliName: String(query[..<colon])) {
            candidates = accounts.filter { $0.provider == provider }
            name = String(query[query.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return one(candidates) }
        }
        let lower = name.lowercased()
        let rules: [(String) -> Bool] = [{ $0 == lower }, { $0.hasPrefix(lower) }, { $0.contains(lower) }]
        for rule in rules {
            let hits = candidates.filter { rule($0.label.lowercased()) }
            if !hits.isEmpty { return one(hits) }
        }
        return .none
    }

    private static func one(_ hits: [ControlAccount]) -> AccountMatch {
        switch hits.count {
        case 0: .none
        case 1: .found(hits[0])
        default: .ambiguous(hits)
        }
    }
}

// MARK: Text

/// `openaccs status` as text: grouped like the panel, numbered, what's LEFT per window and when it comes back.
public struct StatusText: Sendable {
    public var now: Date
    /// ANSI color (only for a terminal, and never with NO_COLOR).
    public var color: Bool
    public var timeZone: TimeZone

    public init(now: Date = Date(), color: Bool = false, timeZone: TimeZone = .current) {
        self.now = now
        self.color = color
        self.timeZone = timeZone
    }

    /// Every account (or one provider's), with numbers that always count over the whole list.
    public func render(_ accounts: [ControlAccount], only: Provider? = nil, notice: String? = nil) -> String {
        var lines: [String] = []
        if let notice { lines += [paint(notice, .yellow), ""] }
        let shown = accounts.enumerated().filter { only == nil || $0.element.provider == only }
        guard !shown.isEmpty else {
            lines.append(only.map { "No \($0.displayName) accounts. Add one: openaccs add \(Self.addName($0))" }
                ?? "No accounts yet. Add one: openaccs add claude <name>")
            return lines.joined(separator: "\n") + "\n"
        }
        let layout = Layout(numberWidth: String(accounts.count).count,
                            titleWidth: min(36, shown.map { Self.title($0.element).count }.max() ?? 0))
        var first = true
        for section in PanelSection.allCases {
            let rows = shown.filter { section.includes($0.element.provider) }
            guard !rows.isEmpty else { continue }
            if !first { lines.append("") }
            first = false
            lines.append(paint(section.title, .bold))
            for (i, account) in rows { lines += block(account, number: i + 1, layout: layout) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One account as in `render`, on its own (for `openaccs best`).
    public func render(_ account: ControlAccount, number: Int) -> String {
        block(account, number: number, layout: Layout(numberWidth: String(number).count, titleWidth: Self.title(account).count))
            .joined(separator: "\n") + "\n"
    }

    struct Layout {
        var numberWidth: Int
        var titleWidth: Int
    }

    func block(_ a: ControlAccount, number: Int, layout: Layout) -> [String] {
        let num = String(repeating: " ", count: max(0, layout.numberWidth - String(number).count)) + String(number)
        let dot = a.state == .idle ? paint("○", .dim) : paint("●", .green)
        let title = Self.title(a)
        var head = "\(num) \(dot) \(paint(title, .bold))"
        let tail = [a.plan.map { paint($0, .dim) }, a.best ? paint("✦", .yellow) : nil].compactMap { $0 }
        if !tail.isEmpty {
            head += String(repeating: " ", count: max(0, layout.titleWidth - title.count)) + "  " + tail.joined(separator: "  ")
        }
        let indent = String(repeating: " ", count: layout.numberWidth + 3)
        var lines = [head]
        for w in a.mainWindows { lines.append(indent + meter(w)) }
        let notes = notes(a, number: number)
        if !notes.isEmpty { lines.append(indent + notes) }
        return lines
    }

    /// `5h  ━━━━━━━───   72% left · resets in 1h 12m`
    func meter(_ w: ControlAccount.Window) -> String {
        let empty = w.usedPercent >= 100
        let cells = empty || w.leftPercent <= 0 ? 0 : max(1, min(10, Int((w.leftPercent / 10).rounded())))
        let tone: Tone = empty ? .red : w.leftPercent < 21 ? .yellow : .plain   // 20% left or less, as shown
        let bar = paint(String(repeating: "━", count: cells), tone) + paint(String(repeating: "─", count: 10 - cells), .dim)
        let name = Self.windowName(w).padding(toLength: 3, withPad: " ", startingAt: 0)
        var text = "\(paint(name, .dim)) \(bar)  " + paint(Self.left(w), tone)
        if let reset = reset(w.resetsAt, empty: empty) { text += paint(" · \(reset)", .dim) }
        return text
    }

    /// "62% left", "<1% left", "empty". Rounded down: never promises more than there is.
    public static func left(_ w: ControlAccount.Window) -> String {
        if w.usedPercent >= 100 { return "empty" }
        if w.leftPercent < 1 { return "<1% left" }
        let n = Int(w.leftPercent.rounded(.down))
        return (n < 10 ? "  " : n < 100 ? " " : "") + "\(n)% left"
    }

    /// "resets in 1h 12m", "resets Thu", "resets Oct 30"; an empty window says "back in …" (same words as the panel).
    public func reset(_ date: Date?, empty: Bool) -> String? {
        guard let date else { return nil }
        let verb = empty ? "back" : "resets"
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes < 1 { return empty ? "back any minute" : "resets now" }
        if minutes < 60 { return "\(verb) in \(minutes)m" }
        if minutes < 24 * 60 { return "\(verb) in \(minutes / 60)h" + (minutes % 60 == 0 ? "" : " \(minutes % 60)m") }
        if minutes < 7 * 24 * 60 - 60 { return "\(verb) \(format(date, "EEE"))" }
        return "\(verb) \(format(date, "MMM d"))"
    }

    /// "updated 45m ago", "updated 2h ago", "updated Oct 18", once numbers are older than 30 minutes.
    public func stale(_ asOf: Date) -> String? {
        let minutes = Int(now.timeIntervalSince(asOf) / 60)
        if minutes < 30 { return nil }
        if minutes < 60 { return "updated \(minutes)m ago" }
        if minutes < 24 * 60 { return "updated \(minutes / 60)h ago" }
        return "updated \(format(asOf, "MMM d"))"
    }

    /// Problems first, then what to do about them, then banked resets, credits and staleness.
    func notes(_ a: ControlAccount, number: Int) -> String {
        var parts: [String] = []
        if let error = a.error {
            parts.append(paint(error, .yellow) + (a.needsSignIn && a.provider == .claude ? paint(" · openaccs connect \(number)", .dim) : ""))
        } else if a.windows.isEmpty {
            parts.append(paint("no limits yet", .dim))
        }
        if a.pendingSessions > 0 {
            let sessions = a.pendingSessions == 1 ? "1 new session" : "\(a.pendingSessions) new sessions"
            parts.append(paint(sessions, .yellow) + paint(" · openaccs restart \(number)", .dim))
        }
        if let n = a.resetsAvailable, n > 0 { parts.append(paint(n == 1 ? "1 reset left" : "\(n) resets left", .dim)) }
        if let c = a.credits { parts.append(paint(Self.credits(c), .dim)) }
        if let asOf = a.asOf, !a.windows.isEmpty, let stale = stale(asOf) { parts.append(paint(stale, .dim)) }
        return parts.joined(separator: paint(" · ", .dim))
    }

    /// "$12.40 balance", "1,200 credits".
    static func credits(_ c: Credits) -> String {
        let en = Locale(identifier: "en_US")
        let isCurrency = c.currency.count == 3 && c.currency == c.currency.uppercased()
        if isCurrency {
            let cents = c.amount.rounded() == c.amount ? 0 : 2
            return c.amount.formatted(.currency(code: c.currency).precision(.fractionLength(cents)).locale(en)) + " " + c.label
        }
        return c.amount.formatted(.number.precision(.fractionLength(0...2)).locale(en)) + " " + c.currency
    }

    static func windowName(_ w: ControlAccount.Window) -> String {
        switch w.kind {
        case .fiveHour: "5h"
        case .weekly: "7d"
        case .monthly: "mo"
        case .other: w.label ?? "·"
        }
    }

    /// The label, plus the provider for Limits rows whose label doesn't already say it.
    static func title(_ a: ControlAccount) -> String {
        let named = a.provider == .claude || a.provider == .codex || a.label.localizedCaseInsensitiveContains(a.provider.displayName)
        return named ? a.label : "\(a.label) · \(a.provider.displayName)"
    }

    static func addName(_ provider: Provider) -> String {
        provider == .claude ? "claude <name>" : provider.rawValue
    }

    private func format(_ date: Date, _ template: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = template
        return f.string(from: date)
    }

    enum Tone: String {
        case plain = "", bold = "1", dim = "2", green = "32", yellow = "33", red = "31"
    }

    func paint(_ text: String, _ tone: Tone) -> String {
        guard color, tone != .plain, !text.isEmpty else { return text }
        return "\u{1B}[\(tone.rawValue)m\(text)\u{1B}[0m"
    }
}
