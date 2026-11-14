import SwiftUI

struct TreemapView: View {
    @ObservedObject var model: ScanViewModel
    @Environment(\.colorScheme) private var scheme
    @State private var scene = DiskScene()
    @State private var hoveredIndex: Int?
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
            let tiles = displayedKey == key ? scene.tiles : []
            ZStack(alignment: .bottomLeading) {
                Canvas { context, _ in
                    guard let snapshot = model.snapshot else { return }
                    let headers = scene.folders.filter { folder in
                        folder.depth == 1 && folder.rect.width > 128 && folder.rect.height > 93 &&
                        !tiles.contains { $0.nodeID == folder.nodeID && $0.rect == folder.rect }
                    }.map { CGRect(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: 48) }
                    for (index, tile) in tiles.enumerated() {
                        let node = snapshot.nodes[tile.nodeID]
                        let box = tile.rect.insetBy(dx: 0.6, dy: 0.6)
                        guard box.width > 0, box.height > 0 else { continue }
                        if tile.isAggregate, tile.bytes > 0 {
                            var x = box.minX
                            for part in tile.composition where part.bytes > 0 {
                                let width = box.width * Double(part.bytes) / Double(tile.bytes)
                                paint(CGRect(x: x, y: box.minY, width: width, height: box.height), color: part.type.color, in: &context)
                                x += width
                            }
                        } else { paint(box, color: node.fileType.color, in: &context) }
                        if hoveredIndex == index {
                            context.stroke(Path(box.insetBy(dx: 1, dy: 1)), with: .color(.white.opacity(0.8)), lineWidth: 1)
                        }
                        let labelRect = CGRect(x: box.minX, y: box.minY, width: box.width, height: 44)
                        if box.width > 100, box.height > 65, !headers.contains(where: { $0.intersects(labelRect) }) {
                            let remainder = tile.isAggregate && tile.representedIDs != [tile.nodeID]
                            let title = remainder ? "Other items in \(node.name)" : node.name
                            label(title, subtitle: "\(formatBytes(tile.bytes))\(tile.isAggregate ? " · grouped" : "")", rect: box, context: &context)
                        }
                    }
                    // Only label immediate folder groups. Deeper nesting remains visible as fine boundaries.
                    if displayedKey == key {
                        for folder in scene.folders where folder.nodeID != model.currentRoot && folder.depth <= 3 {
                            let box = folder.rect.insetBy(dx: 1.5, dy: 1.5)
                            guard box.width > 12, box.height > 12 else { continue }
                            context.stroke(Path(box), with: .color(.black.opacity(folder.depth == 1 ? 0.55 : 0.22)), lineWidth: folder.depth == 1 ? 2 : 1)
                            if folder.depth == 1, box.width > 125, box.height > 90,
                               !tiles.contains(where: { $0.nodeID == folder.nodeID && $0.rect == folder.rect }) {
                                let node = snapshot.nodes[folder.nodeID]
                                label(node.name, subtitle: formatBytes(node.bytes(model.metric)), rect: box, context: &context)
                            }
                        }
                        if let id = model.selectedID, id != model.currentRoot {
                            let selection = snapshot.nodes[id].isDirectory
                                ? scene.folders.first(where: { $0.nodeID == id })?.rect
                                : tiles.first(where: { $0.nodeID == id && !$0.isAggregate })?.rect
                            if let selection {
                                let path = Path(selection.insetBy(dx: 2, dy: 2))
                                context.stroke(path, with: .color(.black.opacity(0.65)), lineWidth: 5)
                                context.stroke(path, with: .color(.white), lineWidth: 2)
                            }
                        }
                    }
                }
                .accessibilityLabel("Disk usage by file type. Named folder groups contain their files. Use the file outline for keyboard navigation.")
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoveredIndex = tiles.firstIndex { $0.rect.contains(point) }
                    case .ended: hoveredIndex = nil
                    }
                }
                .onTapGesture(count: 2) { point in
                    guard let tile = tiles.first(where: { $0.rect.contains(point) }), let snapshot = model.snapshot else { return }
                    let node = snapshot.nodes[tile.nodeID]
                    model.zoom(to: node.isDirectory ? node.id : node.parent ?? 0)
                }
                .onTapGesture { point in
                    model.selectedID = tiles.first(where: { $0.rect.contains(point) })?.nodeID
                }
                if let index = hoveredIndex, tiles.indices.contains(index), let snapshot = model.snapshot {
                    let tile = tiles[index]
                    let node = snapshot.nodes[tile.nodeID]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.name).fontWeight(.semibold)
                        Text("\(formatBytes(tile.bytes))\(tile.isAggregate ? " · grouped contents · double-click to explore" : "")")
                        Text(node.url.path).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        if tile.isAggregate {
                            Text(tile.composition.prefix(3).map { "\($0.type.displayName) \(formatBytes($0.bytes))" }.joined(separator: " · "))
                                .foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .font(.caption).padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(10).allowsHitTesting(false)
                }
                if displayedKey != key {
                    ProgressView("Laying out files…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tiles.isEmpty {
                    ContentUnavailableView("No sized files", systemImage: "square.dashed",
                        description: Text("This folder is empty, unreadable, or contains only zero-byte files for the selected size measure."))
                }
            }
            .task(id: key) {
                hoveredIndex = nil
                guard let snapshot = model.snapshot else { return }
                let task = Task.detached(priority: .userInitiated) {
                    DiskTreemapLayout.scene(snapshot: snapshot, root: key.root, metric: key.metric,
                        frame: CGRect(origin: .zero, size: key.size))
                }
                let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                if !Task.isCancelled { scene = result; displayedKey = key }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func paint(_ rect: CGRect, color: Color, in context: inout GraphicsContext) {
        context.fill(Path(rect), with: .color(color))
        context.fill(Path(rect), with: .linearGradient(Gradient(colors: [.white.opacity(scheme == .dark ? 0.12 : 0.18), .clear, .black.opacity(0.18)]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    private func label(_ title: String, subtitle: String, rect: CGRect, context: inout GraphicsContext) {
        let band = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 44)
        context.fill(Path(band), with: .linearGradient(Gradient(colors: [.black.opacity(0.65), .black.opacity(0.28)]),
            startPoint: CGPoint(x: band.midX, y: band.minY), endPoint: CGPoint(x: band.midX, y: band.maxY)))
        context.draw(Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.white),
            in: CGRect(x: band.minX + 7, y: band.minY + 5, width: band.width - 14, height: 15))
        context.draw(Text(subtitle).font(.system(size: 10)).foregroundColor(.white.opacity(0.85)),
            in: CGRect(x: band.minX + 7, y: band.minY + 23, width: band.width - 14, height: 13))
    }
}
