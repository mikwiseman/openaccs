import SwiftUI
import OpenAccsCore

@main
struct OpenAccsApp: App {
    @State private var model: any PanelModel

    init() {
        // Apps and CLIs we launch inherit our environment; never pass another profile's config folder on.
        ProcessRunner.scrubOwnEnvironment()
        Snapshot.runIfRequested(live: { AppModel(readOnly: true) })
        _model = State(initialValue: Self.makeModel())
    }

    @MainActor static func makeModel() -> any PanelModel { AppModel() }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarIcon(usage: model.menuBarUsage)
        }
        .menuBarExtraStyle(.window)
    }
}
