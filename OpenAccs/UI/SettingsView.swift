import SwiftUI

/// The Settings window: General, and Setup (what Claude and Codex share).
struct SettingsWindow: View {
    let model: any PanelModel
    let updater: AppUpdater
    let setup: SetupModel
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            SettingsView(model: model, updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            SetupView(model: setup)
                .frame(width: 520, height: 440)
                .tabItem { Label("Setup", systemImage: "square.stack.3d.up") }
                .tag("setup")
        }
    }
}

/// What OpenAccs does on its own.
struct SettingsView: View {
    let model: any PanelModel
    let updater: AppUpdater

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenAccs").font(.system(size: 15, weight: .semibold))
                        Text("Version \(AppUpdater.version)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
            Section("Claude windows") {
                Toggle(isOn: Binding(get: { model.syncPins }, set: { model.syncPins = $0 })) {
                    Text("Sync pinned chats")
                    Text("Chats, modes and models always sync. Off, each window pins its own.")
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                    .disabled(updater.unavailable != nil)
                LabeledContent {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                } label: {
                    Text(updater.unavailable ?? "Each update asks before it installs.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
