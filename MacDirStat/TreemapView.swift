import SwiftUI

struct TreemapView: View {
    @ObservedObject var model: ScanViewModel
    @State private var tiles: [DiskTile] = []
    @State private var hovered: DiskTile?
    @State private var displayedKey: LayoutKey?

    private struct LayoutKey: Equatable {
        let date: Date?
        let root: Int
        let metric: SizeMetric
        let size: CGSize
    }

    var body: some View {
        GeometryReader { geometry in
            let key = LayoutKey(date: model.snapshot?.scannedAt, root: model.currentRoot, metric: model.metric, size: geometry.size)
            let visibleTiles = displayedKey == key ? tiles : []
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    guard let snapshot = model.snapshot else { return }
                    for tile in visibleTiles {
                        guard snapshot.nodes.indices.contains(tile.nodeID) else { continue }
                        let node = snapshot.nodes[tile.nodeID]
                        let inset = tile.rect.insetBy(dx: 0.5, dy: 0.5)
                        guard inset.width > 0, inset.height > 0 else { continue }
                        let selected = model.selectedID.map { id in
                            snapshot.nodes.indices.contains(id) &&
                            tile.nodeID >= id && tile.nodeID <= id + snapshot.nodes[id].descendantCount
                        } ?? false
                        let color = node.fileType.color.opacity(hovered?.nodeID == tile.nodeID ? 0.95 : 0.75)
                        context.fill(Path(inset), with: .color(color))
                        if selected {
                            context.stroke(Path(inset.insetBy(dx: 1, dy: 1)), with: .color(.primary), lineWidth: 2)
                        }
                        if inset.width > 65, inset.height > 30 {
                            let label = tile.groupedCount > 0 ? "\(tile.groupedCount) smaller items" : node.name
                            let text = Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                            context.draw(context.resolve(text), in: inset.insetBy(dx: 5, dy: 5))
                        }
                    }
                }
                .accessibilityLabel("Disk usage treemap. Use the file outline to select files with the keyboard.")
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hovered = visibleTiles.first { $0.rect.contains(location) }
                    case .ended: hovered = nil
                    }
                }
                .onTapGesture(count: 2) { location in
                    guard let tile = visibleTiles.first(where: { $0.rect.contains(location) }),
                          let snapshot = model.snapshot else { return }
                    guard snapshot.nodes.indices.contains(tile.nodeID) else { return }
                    let node = snapshot.nodes[tile.nodeID]
                    model.zoom(to: node.isDirectory ? node.id : node.parent ?? 0)
                }
                .onTapGesture { location in
                    model.selectedID = visibleTiles.first { $0.rect.contains(location) }?.nodeID
                }
                if displayedKey == key, let hovered, let snapshot = model.snapshot, snapshot.nodes.indices.contains(hovered.nodeID) {
                    let node = snapshot.nodes[hovered.nodeID]
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hovered.groupedCount > 0 ? "\(hovered.groupedCount) items grouped for display" : node.name).fontWeight(.semibold)
                        if hovered.groupedCount == 0 { Text(formatBytes(node.bytes(model.metric))) }
                        Text(node.url.path).lineLimit(2).truncationMode(.middle)
                    }
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                    .allowsHitTesting(false)
                }
                if displayedKey != key {
                    ProgressView("Laying out files…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleTiles.isEmpty {
                    ContentUnavailableView("No sized files", systemImage: "square.dashed",
                        description: Text("This folder is empty, unreadable, or contains only zero-byte files for the selected size measure."))
                }
            }
            .task(id: key) {
                hovered = nil
                tiles = []
                guard let snapshot = model.snapshot else { tiles = []; return }
                let task = Task.detached(priority: .userInitiated) {
                    DiskTreemapLayout.make(snapshot: snapshot, root: key.root, metric: key.metric,
                                           frame: CGRect(origin: .zero, size: key.size))
                }
                let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                if !Task.isCancelled { tiles = result; displayedKey = key }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
