import SwiftUI
import OpenAccsCore

/// One limit window: name · thin capsule · used % · reset. Columns line up across every row.
struct Meter: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let tint = UsageText.tint(window.usedPercent)
        HStack(spacing: 0) {
            Text(UsageText.window(window))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
            Bar(fraction: window.usedPercent / 100, tint: tint)
            Text(UsageText.percent(window.usedPercent))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(tint == .primary ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
                .frame(width: 42, alignment: .trailing)
            Text(UsageText.reset(window.resetsAt, now: now) ?? "")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UsageText.spokenWindow(window))
        .accessibilityValue("\(UsageText.percent(window.usedPercent)) used, \(UsageText.spokenReset(window.resetsAt, now: now))")
    }
}

/// The capsule. Fills from the left and eases to new values.
private struct Bar: View {
    let fraction: Double
    let tint: Color
    @State private var shown = 0.0
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let value = isSnapshot ? fraction : shown
        Capsule()
            .fill(.primary.opacity(0.09))
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    if value > 0 {
                        Capsule()
                            .fill(tint == .primary ? AnyShapeStyle(.primary.opacity(0.62)) : AnyShapeStyle(tint))
                            .frame(width: max(g.size.height, g.size.width * min(value, 1)))
                    }
                }
            }
            .frame(height: 4)
            .onAppear { withAnimation(.smooth(duration: 0.7).delay(0.05)) { shown = fraction } }
            .onChange(of: fraction) { _, new in withAnimation(.smooth(duration: 0.5)) { shown = new } }
    }
}

/// Filled = running or active, ring = idle. Breathes while an action runs and sends out a
/// ripple when one lands.
struct AccountDot: View {
    let color: Color
    let filled: Bool
    var working = false
    var pulse = 0

    var body: some View {
        ZStack {
            if filled {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(color, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
        .phaseAnimator(working ? [1.0, 0.25] : [1.0]) { dot, opacity in
            dot.opacity(opacity)
        } animation: { _ in .easeInOut(duration: 0.6) }
        .background {
            Circle()
                .stroke(color, lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .keyframeAnimator(initialValue: Ripple(), trigger: pulse) { ring, v in
                    ring.scaleEffect(v.scale).opacity(v.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(1, duration: 0)
                        CubicKeyframe(3.4, duration: 0.8)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0.9, duration: 0)
                        CubicKeyframe(0, duration: 0.8)
                    }
                }
        }
        .accessibilityHidden(true)
    }

    private struct Ripple {
        var scale = 1.0
        var opacity = 0.0
    }
}

extension EnvironmentValues {
    /// True while rendering a still image: skip entry animations.
    @Entry var isSnapshot = false
}
