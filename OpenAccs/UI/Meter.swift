import SwiftUI
import OpenAccsCore

/// One limit window: name · what's left as a capsule · "62% left" · reset. Columns line up across
/// every row. An empty window drops the bar and says when it comes back.
struct Meter: View {
    let window: UsageWindow
    let now: Date

    static let nameWidth: CGFloat = 22
    static let leftWidth: CGFloat = 62
    static let resetWidth: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            Text(UsageText.window(window))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.nameWidth, alignment: .leading)
            if UsageText.isEmpty(window) {
                empty
            } else {
                gauge
            }
        }
        .frame(height: 15)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UsageText.spokenWindow(window))
        .accessibilityValue(UsageText.spoken(window, now: now))
    }

    private var gauge: some View {
        let left = UsageText.left(window)
        let tint = UsageText.tint(left: left)
        return HStack(spacing: 0) {
            Bar(fraction: left / 100, tint: tint)
            Text("\(Text(UsageText.percentLeft(window)).foregroundStyle(tint)) \(Text("left").foregroundStyle(.secondary))")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .frame(width: Self.leftWidth, alignment: .trailing)
            if let reset = UsageText.reset(window.resetsAt, now: now) {
                Text(reset)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: Self.resetWidth, alignment: .trailing)
            }
        }
    }

    /// Nothing to read on a bar: say it's empty and when it's back, which is all that matters now.
    private var empty: some View {
        HStack(spacing: 6) {
            Text("Empty")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.red)
            if let back = UsageText.back(window.resetsAt, now: now) {
                Text(back)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

/// What's left, as a capsule: full when untouched, emptying toward the left as it's used.
private struct Bar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        Capsule()
            .fill(.primary.opacity(0.08))
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule()
                        .fill(tint == .primary ? AnyShapeStyle(.primary.opacity(0.42)) : AnyShapeStyle(tint))
                        .frame(width: max(g.size.height, g.size.width * min(fraction, 1)))
                }
            }
            .frame(height: 4)
            .animation(.smooth(duration: 0.5), value: fraction)
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
