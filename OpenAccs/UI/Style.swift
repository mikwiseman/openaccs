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

/// Usage numbers as short words.
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
        case .fiveHour: "5 hours"
        case .weekly: "7 days"
        case .monthly: "month"
        case .other: w.label ?? "limit"
        }
    }

    static func percent(_ used: Double) -> String { "\(Int(used))%" }

    /// Warm from 80 %, red when the window is spent.
    static func tint(_ used: Double) -> Color {
        used >= 100 ? .red : used >= 80 ? .orange : .primary
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

    /// Spoken form of `reset` for VoiceOver.
    static func spokenReset(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        if date.timeIntervalSince(now) < 24 * 3600 {
            return "resets in " + Duration.seconds(max(0, date.timeIntervalSince(now)))
                .formatted(.units(allowed: [.hours, .minutes], width: .wide))
        }
        return "resets " + date.formatted(.dateTime.weekday(.wide).month().day())
    }

    /// "as of 12m ago" once numbers are older than 15 minutes.
    static func stale(_ asOf: Date, now: Date) -> String? {
        let minutes = Int(now.timeIntervalSince(asOf) / 60)
        if minutes < 15 { return nil }
        if minutes < 60 { return "as of \(minutes) min ago" }
        if minutes < 24 * 60 { return "as of \(minutes / 60)h ago" }
        return "as of " + asOf.formatted(.dateTime.month(.abbreviated).day())
    }

    static func credits(_ c: Credits) -> String {
        let isCurrency = c.currency.count == 3 && c.currency == c.currency.uppercased()
        if isCurrency { return c.amount.formatted(.currency(code: c.currency).precision(.fractionLength(0...2))) }
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
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(.capsule)
    }
}

/// Inline text action, accent colored.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
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
