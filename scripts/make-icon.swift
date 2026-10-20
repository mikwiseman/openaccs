#!/usr/bin/env swift
// Draws the OpenAccs app icon and writes every macOS AppIcon size plus Contents.json.
// Usage (from anywhere): swift scripts/make-icon.swift
//
// The mark is the menu-bar gauge grown up: two rings, outer = 5 hours, inner = 7 days,
// with the ✦ that marks the account with the most room left.
import AppKit
import SwiftUI

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appending(path: "OpenAccs/Resources/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
}

let center = CGPoint(x: 512, y: 512)

/// One ring: a faint full track, then an arc from 12 o'clock clockwise, filled with a top-to-bottom gradient.
func ring(_ ctx: CGContext, radius: CGFloat, width: CGFloat, sweep: CGFloat, colors: [CGColor]) {
    let track = CGMutablePath()
    track.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.addPath(track)
    ctx.setLineWidth(width)
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.strokePath()

    let arc = CGMutablePath()
    arc.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * sweep, clockwise: true)
    let outline = arc.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: 512, y: center.y + radius + width),
                           end: CGPoint(x: 512, y: center.y - radius - width), options: [])
    ctx.restoreGState()
}

/// ✦: four points joined by inward curves.
func sparkle(_ ctx: CGContext, size r: CGFloat, fill: CGColor) {
    let k = r * 0.16
    let p = CGMutablePath()
    p.move(to: CGPoint(x: center.x, y: center.y + r))
    p.addQuadCurve(to: CGPoint(x: center.x + r, y: center.y), control: CGPoint(x: center.x + k, y: center.y + k))
    p.addQuadCurve(to: CGPoint(x: center.x, y: center.y - r), control: CGPoint(x: center.x + k, y: center.y - k))
    p.addQuadCurve(to: CGPoint(x: center.x - r, y: center.y), control: CGPoint(x: center.x - k, y: center.y - k))
    p.addQuadCurve(to: CGPoint(x: center.x, y: center.y + r), control: CGPoint(x: center.x - k, y: center.y + k))
    ctx.addPath(p)
    ctx.setFillColor(fill)
    ctx.fillPath()
}

/// The whole icon in 1024-point design space (macOS grid: 824-point body, 100-point margin).
func draw(_ ctx: CGContext) {
    let body = RoundedRectangle(cornerRadius: 185, style: .continuous)
        .path(in: CGRect(x: 100, y: 100, width: 824, height: 824)).cgPath
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x2A2B33), color(0x0D0D11)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    ring(ctx, radius: 262, width: 72, sweep: 0.74, colors: [color(0xFFB547), color(0xFF5436)])
    ring(ctx, radius: 160, width: 72, sweep: 0.42, colors: [color(0xFFFFFF), color(0xD5D8E2)])
    sparkle(ctx, size: 58, fill: color(0xFFC46B))
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!.retagging(with: .sRGB)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(ctx)
    ctx.flush()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: points * scale).write(to: iconSet.appending(path: name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appending(path: "Contents.json"))
print("Wrote \(images.count) icons to \(iconSet.path(percentEncoded: false))")
