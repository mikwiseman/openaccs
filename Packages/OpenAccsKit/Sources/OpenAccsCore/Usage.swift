import Foundation

/// One limit window, normalized across providers.
public struct UsageWindow: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case fiveHour, weekly, monthly, other
    }

    public var kind: Kind
    /// Extra name for model- or feature-scoped windows ("Opus", "MCP", "Spark"). nil for the main ones.
    public var label: String?
    /// 0...100.
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(kind: Kind, label: String? = nil, usedPercent: Double, resetsAt: Date? = nil) {
        self.kind = kind
        self.label = label
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
    }

    /// The window at `now`: once its reset has passed it is full again, and the next reset isn't known yet.
    public func at(_ now: Date) -> UsageWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        return UsageWindow(kind: kind, label: label, usedPercent: 0)
    }
}

/// Money-like balance: prepaid credits, extra usage spent, wallet.
public struct Credits: Codable, Hashable, Sendable {
    public var amount: Double
    /// ISO currency code ("USD") or a unit word ("credits").
    public var currency: String
    /// What the number means, e.g. "balance", "extra usage".
    public var label: String

    public init(amount: Double, currency: String, label: String) {
        self.amount = amount
        self.currency = currency
        self.label = label
    }
}

public struct UsageSnapshot: Codable, Hashable, Sendable {
    public var plan: String?
    public var windows: [UsageWindow]
    public var credits: Credits?
    /// Banked "limit resets" the account can spend. nil = provider doesn't expose it.
    public var resetsAvailable: Int?
    /// When the provider measured these numbers (not when we fetched them).
    public var asOf: Date
    /// Where the numbers came from, for the UI ("Claude app", "Claude Code", "ChatGPT", "API key").
    public var source: String

    public init(plan: String? = nil, windows: [UsageWindow], credits: Credits? = nil, resetsAvailable: Int? = nil, asOf: Date, source: String) {
        self.plan = plan
        self.windows = windows
        self.credits = credits
        self.resetsAvailable = resetsAvailable
        self.asOf = asOf
        self.source = source
    }

    public func window(_ kind: UsageWindow.Kind) -> UsageWindow? {
        windows.first { $0.kind == kind && $0.label == nil }
    }

    /// These numbers at `now`: a window whose reset has passed is full, however old the reading.
    public func at(_ now: Date) -> UsageSnapshot {
        var snapshot = self
        snapshot.windows = windows.map { $0.at(now) }
        return snapshot
    }
}

public enum UsageError: Error, Equatable, Sendable, LocalizedError {
    /// The credential is gone or permanently rejected; the user must sign in again.
    case needsSignIn
    /// Nothing configured for this account yet (no key, no login).
    case notConnected
    /// The provider said this account has no plan with limits.
    case noPlan
    case network(String)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .needsSignIn: "Sign in again"
        case .notConnected: "Not connected"
        case .noPlan: "No plan"
        case .network(let m): "Network: \(m)"
        case .unexpected(let m): m
        }
    }
}
