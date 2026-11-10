import AppKit
import SwiftUI
import OpenAccsCore

/// A compact outline: moving an account never invokes its normal click-to-open action.
struct ArrangeAccountsView: View {
    let model: any PanelModel
    let done: () -> Void
    @State private var selection: OrderLine.ID?

    var body: some View {
        let lines = model.panelOrder.groups(model.rows, provider: \.provider).flatMap { section, rows in
            [OrderLine(section: section)] + rows.map { OrderLine(section: section, row: $0) }
        }
        let selected = lines.first { $0.id == selection }
        let siblings = lines.filter { $0.parent == selected?.parent }
        let index = siblings.firstIndex { $0.id == selection }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Arrange accounts").font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Drag sections or accounts into place.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            OrderTable(lines: lines, selection: $selection, move: move)
                .frame(height: min(CGFloat(lines.count) * OrderTable.rowHeight + 20, PanelView.maxListHeight - 64))

            Divider().padding(.horizontal, 20)
            HStack(spacing: 3) {
                Button {
                    if let selected, let index, index > 0 { move(selected, before: siblings[index - 1]) }
                } label: { Image(systemName: "arrow.up") }
                .disabled(index.map { $0 == 0 } ?? true)
                .keyboardShortcut(.upArrow, modifiers: .option)
                .accessibilityLabel("Move up")
                .help("Move up (⌥↑)")
                Button {
                    if let selected, let index, index + 1 < siblings.count {
                        move(selected, before: siblings.dropFirst(index + 2).first)
                    }
                } label: { Image(systemName: "arrow.down") }
                .disabled(index.map { $0 + 1 >= siblings.count } ?? true)
                .keyboardShortcut(.downArrow, modifiers: .option)
                .accessibilityLabel("Move down")
                .help("Move down (⌥↓)")
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.prominentPill)
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.pill)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onExitCommand(perform: done)
    }

    private func move(_ line: OrderLine, before next: OrderLine?) {
        switch line.id {
        case .section:
            model.panelOrder.moveSection(line.section, before: next?.section)
        case .account(let id):
            let group = model.panelOrder.groups(model.rows, provider: \.provider).first { $0.section == line.section }
            guard let group else { return }
            model.panelOrder.moveAccount(id, before: next?.accountID, in: line.section, siblings: group.rows.map(\.id))
        }
    }
}

private struct OrderLine: Identifiable, Equatable {
    enum ID: Hashable { case section(PanelSection), account(UUID) }
    let section: PanelSection
    let accountID: UUID?
    let title: String
    let color: Int?
    let filled: Bool
    var id: ID { accountID.map(ID.account) ?? .section(section) }
    var parent: PanelSection? { accountID == nil ? nil : section }
    var dragID: String { accountID?.uuidString ?? section.rawValue }

    init(section: PanelSection, row: PanelRow? = nil) {
        self.section = section
        accountID = row?.id
        title = row?.label ?? section.title
        color = row?.color
        filled = row.map { $0.state != .idle } ?? false
    }
}

/// AppKit owns the drag session, insertion line, edge scrolling and keyboard selection.
private struct OrderTable: NSViewRepresentable {
    static let rowHeight: CGFloat = 30
    let lines: [OrderLine]
    @Binding var selection: OrderLine.ID?
    let move: (OrderLine, OrderLine?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .inset
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(NSTableColumn(identifier: .init("order")))
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.registerForDraggedTypes([Coordinator.pasteboardType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setAccessibilityLabel("Account and section order")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let changed = coordinator.view.lines != lines
        coordinator.view = self
        guard changed else { return }
        coordinator.reloading = true
        table.reloadData()
        if let index = lines.firstIndex(where: { $0.id == selection }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
        }
        coordinator.reloading = false
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let pasteboardType = NSPasteboard.PasteboardType("is.wai.openaccs.panel-item")
        var view: OrderTable
        var reloading = false

        init(_ view: OrderTable) { self.view = view }

        func numberOfRows(in tableView: NSTableView) -> Int { view.lines.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let line = view.lines[row]
            let movable = view.lines.contains { $0.parent == line.parent && $0.id != line.id }
            return OrderCell(rootView: HStack(spacing: 8) {
                if let color = line.color {
                    AccountDot(color: AccountColor.color(color), filled: line.filled)
                }
                Text(line.title)
                    .font(.system(size: line.accountID == nil ? 12 : 13, weight: line.accountID == nil ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.middle)
                if line.accountID == nil {
                    Rectangle().fill(.separator).frame(height: 0.5)
                } else {
                    Spacer(minLength: 4)
                }
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(movable ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.leading, line.accountID == nil ? 4 : 16)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.accountID == nil ? "\(line.title) section" : line.title))
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !reloading, let table = notification.object as? NSTableView else { return }
            view.selection = view.lines.indices.contains(table.selectedRow) ? view.lines[table.selectedRow].id : nil
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            let line = view.lines[row]
            guard view.lines.contains(where: { $0.parent == line.parent && $0.id != line.id }) else { return nil }
            let item = NSPasteboardItem()
            item.setString(line.dragID, forType: Self.pasteboardType)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard let drop = destination(info, in: tableView) else { return [] }
            tableView.setDropRow(drop.gap, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let drop = destination(info, in: tableView) else { return false }
            let anchor = view.lines.dropFirst(drop.gap).first
            view.selection = drop.source.id
            view.move(drop.source, anchor?.parent == drop.source.parent ? anchor : nil)
            return true
        }

        /// Sections snap around whole groups. Accounts can only land between siblings.
        private func destination(_ info: any NSDraggingInfo, in table: NSTableView) -> (source: OrderLine, gap: Int)? {
            let lines = view.lines
            guard info.draggingSource as? NSTableView === table,
                  let key = info.draggingPasteboard.string(forType: Self.pasteboardType),
                  let source = lines.first(where: { $0.dragID == key }) else { return nil }
            let point = table.convert(info.draggingLocation, from: nil)
            let hit = table.row(at: point)
            var gap = point.y < table.rect(ofRow: 0).minY ? 0 : lines.count
            if lines.indices.contains(hit) {
                if source.accountID == nil {
                    let section = lines[hit].section
                    guard let first = lines.firstIndex(where: { $0.section == section }),
                          let last = lines.lastIndex(where: { $0.section == section }) else { return nil }
                    let middle = (table.rect(ofRow: first).minY + table.rect(ofRow: last).maxY) / 2
                    gap = point.y < middle ? first : last + 1
                } else {
                    gap = point.y < table.rect(ofRow: hit).midY ? hit : hit + 1
                }
            }
            if source.accountID != nil {
                guard gap > 0, lines[gap - 1].section == source.section else { return nil }
            }
            return (source, gap)
        }
    }
}

/// The cell is a label. Let its table row receive mouse-downs, including on the grip.
private final class OrderCell<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
