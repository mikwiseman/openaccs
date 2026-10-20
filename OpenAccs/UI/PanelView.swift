import SwiftUI
import OpenAccsCore

/// The popover: accounts grouped by product, then a footer. Adding happens in place.
struct PanelView: View {
    let model: any PanelModel
    @State private var adding: Provider?

    init(model: any PanelModel, adding: Provider? = nil) {
        self.model = model
        _adding = State(initialValue: adding)
    }

    static let width: CGFloat = 340

    var body: some View {
        Group {
            if let provider = adding {
                AddAccountView(provider: provider, model: model) { adding = nil }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list.transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: Self.width)
        .animation(.snappy(duration: 0.3), value: adding)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let sections = Section.allCases.map { s in (s, model.rows.filter { s.includes($0.provider) }) }
                    .filter { !$0.1.isEmpty }
                VStack(alignment: .leading, spacing: 2) {
                    if let notice = model.notice {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    ForEach(sections, id: \.0) { section, rows in
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, section == sections.first?.0 ? 4 : 12)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(rows) { row in
                            AccountRow(row: row, model: model, now: context.date) { adding = $0 }
                        }
                    }
                    if sections.isEmpty { empty }
                }
            }
            .padding(8)
            Divider().padding(.horizontal, 20)
            footer
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add your first account").font(.system(size: 13, weight: .semibold))
            Text("Switch between Claude and Codex accounts, and watch limits for Grok, Kimi and Z.ai.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(Provider.allCases, id: \.self) { provider in
                    Button(provider.displayName) { adding = provider }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.quiet)
            .fixedSize()
            Spacer()
            if model.isRefreshing {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .symbolEffect(.rotate.byLayer, options: .repeat(.continuous))
                    .accessibilityLabel("Refreshing")
            }
            Menu {
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
                Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Divider()
                Button("Quit OpenAccs") { model.quit() }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.quiet)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    enum Section: CaseIterable {
        case claude, codex, limits

        var title: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            case .limits: "Limits"
            }
        }

        func includes(_ provider: Provider) -> Bool {
            switch self {
            case .claude: provider == .claude
            case .codex: provider == .codex
            case .limits: provider != .claude && provider != .codex
            }
        }
    }
}
