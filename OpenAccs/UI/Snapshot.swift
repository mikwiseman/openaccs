import SwiftUI
import AppKit
import OpenAccsCore
import SetupKit

/// `OpenAccs --snapshot <png> [--demo] [--dark] [--add <provider> | --connect | --settings | --setup]` renders the
/// panel (or an add view, the guided connect of the first Claude row without live limits, the Settings window or
/// its Setup tab) at 2x to a PNG and exits, without a menu-bar item. For checking the UI without clicking. A live
/// `--setup` scans this Mac (read only) first.
///
/// Draws through an offscreen NSHostingView rather than ImageRenderer, because ImageRenderer
/// can't draw AppKit-backed controls (text fields come out as placeholders).
enum Snapshot {
    @MainActor static func runIfRequested(live: (_ readOnly: Bool) -> any PanelModel) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot") else { return }
        guard args.indices.contains(i + 1) else { fail("--snapshot needs a file path") }
        let out = URL(filePath: args[i + 1])
        var adding: Provider?
        if let a = args.firstIndex(of: "--add") {
            guard args.indices.contains(a + 1), let p = Provider(rawValue: args[a + 1]) else {
                fail("--add needs one of: " + Provider.allCases.map(\.rawValue).joined(separator: ", "))
            }
            adding = p
        }

        NSApplication.shared.setActivationPolicy(.prohibited)
        #if DEBUG
        let interactive = args.contains("--interactive") && Paths.isOverridden
        #else
        let interactive = false
        #endif
        let model: any PanelModel = args.contains("--demo") ? DemoModel() : live(!interactive)
        // A live model loads asynchronously; give it up to 30 s.
        if let live = model as? AppModel {
            let deadline = Date().addingTimeInterval(30)
            while !live.isReady, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        let root: AnyView
        if args.contains("--instructions") {
            root = AnyView(InstructionsView(model: InstructionsModel(context: { SetupService.context() }))
                .frame(width: 900, height: 620))
        } else if args.contains("--setup") {
            let setup = args.contains("--demo") ? SetupModel(demo: SetupModel.demoReports)
                : SetupModel(context: { SetupService.context() }, scan: OneSetup.scan)
            Task { await setup.refresh() }
            let deadline = Date().addingTimeInterval(60)
            repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) } while (setup.isScanning || setup.reports.isEmpty) && Date() < deadline
            root = args.contains("--review")
                ? AnyView(ReviewSheet(model: setup, selected: Set(setup.reports.recommendedChanges.map(\.id))) {})
                : AnyView(SetupView(model: setup).frame(width: 580, height: 700))
        } else if args.contains("--settings") {
            root = AnyView(SettingsView(model: model, updater: AppUpdater.shared))
        } else {
            let connecting = args.contains("--connect") ? model.rows.first { $0.provider == .claude && $0.needsSignIn }?.id : nil
            root = AnyView(PanelView(model: model, adding: adding, connecting: connecting))
        }
        let host = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        window.contentView = host
        // The list measures itself to size its scroll view; let that settle before drawing.
        for _ in 0..<20 {
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if host.fittingSize == host.frame.size { break }
        }

        let size = host.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { fail("no bitmap") }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG encoding failed") }
        do { try png.write(to: out) } catch { fail(error.localizedDescription) }
        #if DEBUG
        // Keep the rendered fixture available to background UI automation, without taking focus.
        if interactive {
            if let model = model as? AppModel { ControlHandler.start(model: model) }
            NSApplication.shared.setActivationPolicy(.accessory)
            window.styleMask = [.titled, .closable]
            window.title = "OpenAccs — Test profiles"
            window.orderBack(nil)
            NSApplication.shared.run()
        }
        #endif
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
        exit(1)
    }
}
