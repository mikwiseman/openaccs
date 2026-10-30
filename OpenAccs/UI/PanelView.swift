import SwiftUI
import OpenAccsCore

/// The popover: accounts grouped by product, then a footer. Adding happens in place.
struct PanelView: View {
    let model: any PanelModel
    @State private var adding: Provider?
    /// The Claude window whose account the guided connect is for.
    @State private var connecting: UUID?
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"
    @State private var listHeight: CGFloat = 0
    /// Which ends of the scrolling list have more beyond them, to fade those edges.
    @State private var overflow: Edge.Set = []

    init(model: any PanelModel, adding: Provider? = nil, connecting: UUID? = nil) {
        self.model = model
        _adding = State(initialValue: adding)
        _connecting = State(initialValue: connecting)
    }

    static let width: CGFloat = 340
    /// The account list scrolls past this, so a long list never outgrows a laptop screen.
    static let maxListHeight: CGFloat = 680

    var body: some View {
        Group {
            if let provider = adding {
                AddAccountView(provider: provider, model: model) { adding = nil }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let id = connecting {
                AddAccountView(provider: .claude, connecting: id, model: model) { connecting = nil }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list.transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: Self.width)
        .animation(.snappy(duration: 0.3), value: adding)
        .animation(.snappy(duration: 0.3), value: connecting)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        accounts(now: context.date, proxy: proxy)
                    }
                    .padding(8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: Edge.Set.self) { g in
                    var edges: Edge.Set = []
                    if g.contentOffset.y > 1 { edges.insert(.top) }
                    if g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1 { edges.insert(.bottom) }
                    return edges
                } action: { _, new in overflow = new }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(overflow.contains(.top) ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(overflow.contains(.bottom) ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 32)
                }
            }
            .frame(height: min(listHeight, Self.maxListHeight))
            Divider().padding(.horizontal, 20)
            footer
        }
    }

    private func accounts(now: Date, proxy: ScrollViewProxy) -> some View {
        let sections = Section.allCases.map { s in (s, model.rows.filter { s.includes($0.provider) }) }
            .filter { !$0.1.isEmpty }
        return VStack(alignment: .leading, spacing: 2) {
            if let notice = model.notice {
                Label {
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 6)
            }
            ForEach(sections, id: \.0) { section, rows in
                Text(section.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, section == sections.first?.0 ? 4 : 14)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(rows) { row in
                    AccountRow(row: row, model: model, now: now) {
                        // Once the question below the row is laid out: scroll just enough to show all of it.
                        Task { withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo("reveal \(row.id)") } }
                    } signIn: { row in
                        if row.provider == .claude { connecting = row.id } else { adding = row.provider }
                    }
                    // What that scrolls to: the row, plus room for the list's faded bottom edge.
                    .background { Color.clear.id("reveal \(row.id)").padding(.bottom, -32) }
                }
            }
            if sections.isEmpty { empty }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add your first account").font(.system(size: 13, weight: .semibold))
                Text("Switch between Claude and Codex accounts and see what's left on each. Grok, Kimi and Z.ai show their limits too.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    Button(provider.displayName) { adding = provider }
                        .buttonStyle(.pill)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(Provider.allCases, id: \.self) { provider in
                    Button(provider.displayName) { adding = provider }
                }
            } label: {
                Label("Add account", systemImage: "plus")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.quiet)
            .fixedSize()
            Spacer()
            Button { model.refresh() } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive: model.isRefreshing)
            }
            .buttonStyle(.quiet)
            .disabled(model.isRefreshing)
            .help("Refresh limits")
            .accessibilityLabel(model.isRefreshing ? "Refreshing" : "Refresh limits")
            .keyboardShortcut("r")
            Menu {
                Button("Setup…") { showSettings("setup") }
                Button("Settings…") { showSettings("general") }
                    .keyboardShortcut(",")
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                Divider()
                Button("Quit OpenAccs") { model.quit() }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.quiet)
            .fixedSize()
            .accessibilityLabel("OpenAccs settings and more")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A menu-bar app isn't frontmost: bring it forward, or the window opens behind others.
    private func showSettings(_ tab: String) {
        settingsTab = tab
        NSApp.activate()
        openSettings()
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
