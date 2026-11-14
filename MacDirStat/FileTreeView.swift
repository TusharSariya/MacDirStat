import SwiftUI
import AppKit

/// AppKit's outline virtualizes rows and expands ancestors when a treemap file is selected.
struct FileTreeView: NSViewRepresentable {
    @ObservedObject var model: ScanViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let outline = NSOutlineView()
        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Name"
        name.width = 240
        name.minWidth = 120
        name.headerToolTip = "Sort by name"
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "Size"
        size.width = 100
        size.headerToolTip = "Sort largest first"
        outline.addTableColumn(name)
        outline.addTableColumn(size)
        outline.outlineTableColumn = name
        outline.style = .sourceList
        outline.rowSizeStyle = .medium
        outline.delegate = context.coordinator
        outline.dataSource = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.openDirectory)
        outline.allowsEmptySelection = true
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.refresh()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var model: ScanViewModel
        weak var outline: NSOutlineView?
        var snapshotDate: Date?
        var sort: DiskSort?
        var metric: SizeMetric?
        var children: [Int: [Int]] = [:]
        var updating = false
        init(model: ScanViewModel) { self.model = model }

        func refresh() {
            guard let outline else { return }
            updating = true
            defer { updating = false }
            if snapshotDate != model.snapshot?.scannedAt || sort != model.sort || metric != model.metric {
                snapshotDate = model.snapshot?.scannedAt
                sort = model.sort
                metric = model.metric
                children.removeAll(keepingCapacity: true)
                outline.reloadData()
                outline.expandItem(NSNumber(value: 0))
            }
            if let snapshot = model.snapshot, let id = model.selectedID {
                for ancestor in snapshot.ancestors(of: id).dropLast() {
                    outline.expandItem(NSNumber(value: ancestor))
                }
                let row = outline.row(forItem: NSNumber(value: id))
                if row >= 0, outline.selectedRow != row {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            } else { outline.deselectAll(nil) }
        }

        func childIDs(_ item: Any?) -> [Int] {
            guard let snapshot = model.snapshot else { return [] }
            guard let id = (item as? NSNumber)?.intValue else { return [0] }
            if let cached = children[id] { return cached }
            let ids = snapshot.children(of: id, sortedBy: model.sort, metric: model.metric)
            children[id] = ids
            return ids
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { childIDs(item).count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { NSNumber(value: childIDs(item)[index]) }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let id = (item as? NSNumber)?.intValue else { return false }
            return !(model.snapshot?.nodes[id].children.isEmpty ?? true)
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let id = (item as? NSNumber)?.intValue, let node = model.snapshot?.nodes[id] else { return nil }
            let identifier = tableColumn!.identifier
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = identifier
            if cell.textField == nil {
                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(text)
                cell.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: identifier.rawValue == "name" ? 24 : 4),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            if identifier.rawValue == "name" {
                if cell.imageView == nil {
                    let icon = NSImageView()
                    icon.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(icon)
                    cell.imageView = icon
                    NSLayoutConstraint.activate([
                        icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                        icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        icon.widthAnchor.constraint(equalToConstant: 16),
                        icon.heightAnchor.constraint(equalToConstant: 16)
                    ])
                }
                cell.imageView?.image = NSImage(systemSymbolName: node.isDirectory ? "folder.fill" : node.isSymbolicLink ? "link" : node.fileType.icon, accessibilityDescription: nil)
                cell.imageView?.contentTintColor = node.isDirectory ? .systemYellow : NSColor(node.fileType.color)
                cell.textField?.stringValue = node.name
                cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
            } else {
                cell.textField?.stringValue = formatBytes(node.bytes(model.metric))
                cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                cell.textField?.alignment = .right
            }
            cell.toolTip = node.url.path
            return cell
        }
        func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn) {
            model.sort = tableColumn.identifier.rawValue == "name" ? .name : .size
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline else { return }
            model.selectedID = (outline.item(atRow: outline.selectedRow) as? NSNumber)?.intValue
        }
        @objc func openDirectory() {
            guard let outline, let id = (outline.item(atRow: outline.clickedRow) as? NSNumber)?.intValue else { return }
            model.zoom(to: id)
        }
    }
}
