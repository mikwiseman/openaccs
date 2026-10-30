import SwiftUI
import AppKit
import OpenAccsCore

/// The colors an account can wear. `PanelRow.color` indexes into `all`.
enum AccountColor {
    static let all: [(name: String, color: Color)] = [
        ("Orange", .orange), ("Blue", .blue), ("Green", .green), ("Purple", .purple),
        ("Pink", .pink), ("Teal", .teal), ("Yellow", .yellow), ("Graphite", .gray),
    ]

    static func color(_ index: Int) -> Color {
        all[((index % all.count) + all.count) % all.count].color
    }

    /// A colored dot for menus, which otherwise draw SwiftUI images as monochrome templates.
    static func swatch(_ index: Int) -> NSImage {
        let fill = NSColor(color(index))
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Usage as people choose accounts: by what's left, never by what's used.
enum UsageText {
    static func window(_ w: UsageWindow) -> String {
        switch w.kind {
        case .fiveHour: "5h"
        case .weekly: "7d"
        case .monthly: "mo"
        case .other: w.label ?? "·"
        }
    }

    static func spokenWindow(_ w: UsageWindow) -> String {
        switch w.kind {
        case .fiveHour: "5-hour limit"
        case .weekly: "7-day limit"
        case .monthly: "monthly limit"
        case .other: "\(w.label ?? "other") limit"
        }
    }

    /// Percent of the window still available, 0...100.
    static func left(_ w: UsageWindow) -> Double { max(0, 100 - w.usedPercent) }

    static func isEmpty(_ w: UsageWindow) -> Bool { w.usedPercent >= 100 }

    /// "62%", "<1%". Rounds down so it never promises more than there is.
    static func percentLeft(_ w: UsageWindow) -> String {
        let left = left(w)
        return left > 0 && left < 1 ? "<1%" : "\(Int(left))%"
    }

    static func spokenLeft(_ w: UsageWindow) -> String {
        isEmpty(w) ? "empty" : "\(percentLeft(w).replacingOccurrences(of: "%", with: "")) percent left"
    }

    /// Calm while there's plenty, warm at 20 % left or less as shown (rounded down), red only when empty.
    static func tint(left: Double) -> Color {
        left <= 0 ? .red : left < 21 ? .orange : .primary
    }

    /// When an empty window refills: "back in 42m", "back in 1h 12m", "back Thu".
    static func back(_ date: Date?, now: Date) -> String? {
        guard let date, let short = reset(date, now: now) else { return nil }
        if short == "now" { return "back any minute" }
        return date.timeIntervalSince(now) < 24 * 3600 ? "back in \(short)" : "back \(short)"
    }

    /// "now", "42m", "1h 12m", "Thu", "Oct 30".
    static func reset(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m" }
        if minutes < 7 * 24 * 60 - 60 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Spoken form of `reset` ("resets in 2 hours, 10 minutes") or, for an empty window, of `back`.
    static func spokenReset(_ date: Date?, now: Date, empty: Bool = false) -> String? {
        guard let date else { return nil }
        let verb = empty ? "back" : "resets"
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return empty ? "back any minute" : "resets now" }
        if seconds < 24 * 3600 {
            return "\(verb) in " + Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .wide))
        }
        return "\(verb) " + date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    /// "62 percent left, resets in 2 hours", read after the window name ("5-hour limit").
    static func spoken(_ w: UsageWindow, now: Date) -> String {
        [spokenLeft(w), spokenReset(w.resetsAt, now: now, empty: isEmpty(w))].compactMap { $0 }.joined(separator: ", ")
    }

    /// "updated 2h ago" once numbers are older than 30 minutes (the slowest source asks every 15).
    static func stale(_ asOf: Date, now: Date) -> String? {
        guard now.timeIntervalSince(asOf) >= 30 * 60 else { return nil }
        return updated(asOf, now: now)
    }

    /// Always shown for measurements saved by another app, even when recent.
    static func updated(_ asOf: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(asOf) / 60)
        if minutes < 1 { return "just updated" }
        if minutes < 60 { return "updated \(minutes)m ago" }
        if minutes < 24 * 60 { return "updated \(minutes / 60)h ago" }
        return "updated " + asOf.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "$12 balance", "$4.20 extra usage", "120 credits".
    static func credits(_ c: Credits) -> String {
        let isCurrency = c.currency.count == 3 && c.currency == c.currency.uppercased()
        if isCurrency {
            let cents = c.amount.rounded() == c.amount ? 0 : 2
            return c.amount.formatted(.currency(code: c.currency).precision(.fractionLength(cents))) + " " + c.label
        }
        return "\(c.amount.formatted(.number.precision(.fractionLength(0...2)))) \(c.currency)"
    }

    static func resets(_ n: Int) -> String { n == 1 ? "1 reset left" : "\(n) resets left" }

    /// Windows worth a meter: the main ones, shortest first.
    static func meters(_ usage: UsageSnapshot?) -> [UsageWindow] {
        let order: [UsageWindow.Kind] = [.fiveHour, .weekly, .monthly]
        return order.compactMap { usage?.window($0) }
    }
}

/// Small caps label on a soft capsule: plans, "experimental".
struct Chip: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(.primary.opacity(0.07)))
            .fixedSize()
    }
}

/// Capsule button. Prominent = filled with the accent color.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(.primary.opacity(0.08)))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

/// Inline text action, accent colored.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(.rect)
            .pointerStyle(.link)
    }
}

/// Borderless icon or text button for the footer, with a soft hover.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietLabel(configuration: configuration)
    }

    private struct QuietLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(hovering ? 0.07 : 0)))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var prominentPill: PillButtonStyle { PillButtonStyle(prominent: true) }
}

extension ButtonStyle where Self == LinkButtonStyle {
    static var inlineLink: LinkButtonStyle { LinkButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

/// Copies a sign-in link to open in another browser window; reads "Copied" for a moment after.
struct CopyLinkButton: View {
    let link: URL
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
        .buttonStyle(.inlineLink)
    }
}

/// Window names as a person says them: "Claude", "Claude and ai44", "A, B and C".
func windowList(_ labels: [String]) -> String {
    guard let last = labels.last else { return "" }
    return labels.count == 1 ? last : labels.dropLast().joined(separator: ", ") + " and " + last
}
