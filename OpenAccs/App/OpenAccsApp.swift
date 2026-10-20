import SwiftUI
import OpenAccsCore

@main
@MainActor
enum Main {
    static func main() {
        // Apps and CLIs we launch inherit our environment; never pass another profile's config folder on.
        ProcessRunner.scrubOwnEnvironment()
        // `openaccs …` asks the running app and exits; it never creates the app's UI.
        if CLI.isRequested(CommandLine.arguments) { exit(CLI.run(CommandLine.arguments)) }
        OpenAccsApp.main()
    }
}

struct OpenAccsApp: App {
    @State private var model: any PanelModel

    init() {
        Snapshot.runIfRequested(live: { AppModel(readOnly: true) })
        _model = State(initialValue: Self.makeModel())
    }

    @MainActor static func makeModel() -> any PanelModel {
        let model = AppModel()
        ControlHandler.start(model: model)
        return model
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarIcon(usage: model.menuBarUsage)
        }
        .menuBarExtraStyle(.window)
    }
}
