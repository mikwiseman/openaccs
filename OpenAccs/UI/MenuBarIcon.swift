import SwiftUI
import AppKit
import OpenAccsCore

/// Menu-bar glyph: two concentric rings showing what's left, outer = 5h, inner = 7d. A full ring is
/// untouched; it empties counterclockwise back to the top as the window is used; an empty ring is out.
/// A template image, so the menu bar tints it for light, dark and highlighted states.
struct MenuBarIcon: View {
    let usage: UsageSnapshot?

    var body: some View {
        let fiveHour = usage?.window(.fiveHour)
        let weekly = usage?.window(.weekly)
        Image(nsImage: Self.image(fiveHourLeft: fiveHour.map(UsageText.left), weeklyLeft: weekly.map(UsageText.left)))
            .accessibilityLabel("OpenAccs")
            .accessibilityValue(Self.spoken(fiveHour: fiveHour, weekly: weekly))
    }

    /// Percent left, 0...100. nil = no reading: a hairline outline, so it never looks like "out".
    static func image(fiveHourLeft: Double?, weeklyLeft: Double?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            ring(center: center, radius: 7.25, width: 2, left: fiveHourLeft)
            ring(center: center, radius: 3.75, width: 2, left: weeklyLeft)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func ring(center: CGPoint, radius: CGFloat, width: CGFloat, left: Double?) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = left == nil ? 1 : width
        NSColor.black.withAlphaComponent(left == nil ? 0.55 : 0.3).setStroke()
        track.stroke()

        guard let left, left > 0 else { return }
        let fraction = min(left, 100) / 100
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        arc.lineWidth = width
        arc.lineCapStyle = fraction < 1 ? .round : .butt
        NSColor.black.setStroke()
        arc.stroke()
    }

    private static func spoken(fiveHour: UsageWindow?, weekly: UsageWindow?) -> String {
        guard fiveHour != nil || weekly != nil else { return "No Claude limits yet" }
        let five = fiveHour.map { "5-hour limit, \(UsageText.spokenLeft($0))" } ?? "5-hour limit unknown"
        let week = weekly.map { "7-day limit, \(UsageText.spokenLeft($0))" } ?? "7-day limit unknown"
        return "Claude \(five); \(week)"
    }
}
