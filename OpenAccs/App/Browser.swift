import AppKit
import ClaudeKit

/// The default browser, and how to open a link in a private window of it.
struct Browser {
    let app: URL
    /// As the browser calls itself ("Brave Browser").
    let name: String
    /// The switch for a private window, or nil when OpenAccs knows none for this browser (Safari).
    let privateFlag: String?

    /// The app that opens https links on this Mac.
    static var current: Browser? {
        guard let probe = URL(string: "https://claude.ai"), let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        let bundle = Bundle(url: app)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? app.deletingPathExtension().lastPathComponent
        return Browser(app: app, name: name, privateFlag: bundle?.bundleIdentifier.flatMap(ClaudeCodeCLI.privateWindowFlag))
    }

    /// In a private window when the browser has one, like `open -na <browser> --args <flag> <link>`, so a
    /// browser that already runs gets the switch too. Otherwise, or if that launch fails, the usual way.
    func open(_ link: URL) {
        guard let privateFlag else {
            NSWorkspace.shared.open(link)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [privateFlag, link.absoluteString]
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            if error != nil { Task { @MainActor in NSWorkspace.shared.open(link) } }
        }
    }
}
