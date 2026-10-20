import SwiftUI
import AppKit
import OpenAccsCore

/// Menu-bar glyph: two concentric arcs, outer = 5h, inner = 7d, filled clockwise from the top.
/// A template image, so the menu bar tints it for light, dark and highlighted states.
struct MenuBarIcon: View {
    let usage: UsageSnapshot?

    var body: some View {
        let fiveHour = usage?.window(.fiveHour)?.usedPercent
        let weekly = usage?.window(.weekly)?.usedPercent
        Image(nsImage: Self.image(fiveHour: fiveHour, weekly: weekly))
            .accessibilityLabel("OpenAccs")
            .accessibilityValue(Self.spoken(fiveHour: fiveHour, weekly: weekly))
    }

    /// Percentages 0...100; nil draws only the track.
    static func image(fiveHour: Double?, weekly: Double?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            ring(center: center, radius: 7.25, width: 2, used: fiveHour)
            ring(center: center, radius: 3.75, width: 2, used: weekly)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func ring(center: CGPoint, radius: CGFloat, width: CGFloat, used: Double?) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        NSColor.black.withAlphaComponent(0.3).setStroke()
        track.stroke()

        guard let used, used > 0 else { return }
        let fraction = min(used, 100) / 100
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        arc.lineWidth = width
        arc.lineCapStyle = fraction < 1 ? .round : .butt
        NSColor.black.setStroke()
        arc.stroke()
    }

    private static func spoken(fiveHour: Double?, weekly: Double?) -> String {
        guard fiveHour != nil || weekly != nil else { return "No Claude usage yet" }
        let five = fiveHour.map { "5 hours \(Int($0))% used" } ?? "5 hours unknown"
        let week = weekly.map { "7 days \(Int($0))% used" } ?? "7 days unknown"
        return "\(five), \(week)"
    }
}
