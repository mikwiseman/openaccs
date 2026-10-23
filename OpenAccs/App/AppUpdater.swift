import AppKit
import Sparkle

/// Updates through Sparkle: a signed feed on GitHub Pages (`SUFeedURL`), checked once a day unless turned
/// off in Settings. Each update asks before it installs.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private(set) var canCheckForUpdates = false
    /// Why updates don't run here, if they don't.
    private(set) var unavailable: String?

    var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    private init() {
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        #if DEBUG
        unavailable = "Development builds don't update."
        #else
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
        do {
            try controller.updater.start()
        } catch {
            unavailable = error.localizedDescription
        }
        #endif
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.updater.checkForUpdates()
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
