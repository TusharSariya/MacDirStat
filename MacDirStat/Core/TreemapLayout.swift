import Foundation
import CoreGraphics

struct DiskTile: Sendable {
    let nodeID: Int
    let rect: CGRect
    var groupedCount = 0
    var representedIDs: [Int] = []
    var bytes: Int64 = 0
    var composition: [TypeSummary] = []
    var isAggregate: Bool { !representedIDs.isEmpty }
}

struct DiskFolderRegion: Sendable {
    let nodeID: Int
    let rect: CGRect
    let depth: Int
}

struct DiskScene: Sendable {
    var tiles: [DiskTile] = []
    var folders: [DiskFolderRegion] = []
}

/// Squarified layout with bounded detail. Subpixel directories are represented by one tile.
/// Very wide directories group their smallest items; the outline still exposes every file.
enum DiskTreemapLayout {
    static func make(snapshot: ScanSnapshot, root: Int, metric: SizeMetric, frame: CGRect,
                     limit: Int = 6000) -> [DiskTile] {
        scene(snapshot: snapshot, root: root, metric: metric, frame: frame, limit: limit).tiles
    }

    static func scene(snapshot: ScanSnapshot, root: Int, metric: SizeMetric, frame: CGRect,
                      limit: Int = 6000) -> DiskScene {
        guard snapshot.nodes.indices.contains(root), limit > 0, frame.width > 0, frame.height > 0, snapshot.nodes[root].bytes(metric) > 0 else { return DiskScene() }
        var result: [DiskTile] = []
        var folders: [DiskFolderRegion] = []
        var pending: [(Int, CGRect, Int, Int)] = [(root, frame, 0, limit)]
        while let (id, rect, depth, budget) = pending.popLast() {
            if Task.isCancelled { return DiskScene() }
            let node = snapshot.nodes[id]
            if node.isDirectory { folders.append(DiskFolderRegion(nodeID: id, rect: rect, depth: depth)) }
            if !node.isDirectory || node.children.isEmpty || rect.width < 5 || rect.height < 5 || depth >= 64 {
                result.append(DiskTile(nodeID: id, rect: rect, groupedCount: node.isDirectory ? node.children.count : 0, representedIDs: node.isDirectory ? [id] : []))
                continue
            }
            let available = max(1, budget)
            let sorted = snapshot.children(of: id, sortedBy: .size, metric: metric)
                .filter { snapshot.nodes[$0].bytes(metric) > 0 }
            guard !sorted.isEmpty else { continue }
            if available < 2 {
                result.append(DiskTile(nodeID: id, rect: rect, groupedCount: node.children.count, representedIDs: [id]))
                continue
            }
            let count = min(sorted.count, min(available == sorted.count ? available : available - 1, 1500))
            var weights = sorted.prefix(count).map { (id: $0, weight: Double(snapshot.nodes[$0].bytes(metric)), grouped: 0) }
            if count < sorted.count {
                let remaining = sorted.dropFirst(count)
                let bytes = remaining.reduce(0.0) { $0 + Double(snapshot.nodes[$1].bytes(metric)) }
                weights.append((id, bytes, remaining.count))
            }
            let total = weights.reduce(0) { $0 + $1.weight }
            let scale = rect.width * rect.height / total
            var remaining = rect
            var descendants: [(Int, CGRect, Int, Int)] = []
            let extraBudget = max(0, available - weights.count)
            var assignedExtra = 0
            var cumulativeWeight = 0.0
            var cursor = 0
            while cursor < weights.count {
                let short = min(remaining.width, remaining.height)
                guard short > 0 else { break }
                var end = cursor + 1
                var sum = weights[cursor].weight * scale
                let maximum = sum
                var minimum = sum
                func worst(_ sum: Double, _ minimum: Double) -> Double {
                    guard sum > 0, minimum > 0 else { return .infinity }
                    return max(short * short * maximum / (sum * sum), sum * sum / (short * short * minimum))
                }
                while end < weights.count {
                    let next = weights[end].weight * scale
                    if worst(sum + next, min(minimum, next)) > worst(sum, minimum) { break }
                    sum += next
                    minimum = min(minimum, next)
                    end += 1
                }
                let vertical = remaining.width >= remaining.height
                let thickness = sum / short
                var offset = vertical ? remaining.minY : remaining.minX
                for index in cursor..<end {
                    let item = weights[index]
                    let length = item.weight * scale / thickness
                    let box = vertical
                        ? CGRect(x: remaining.minX, y: offset, width: thickness, height: length)
                        : CGRect(x: offset, y: remaining.minY, width: length, height: thickness)
                    offset += length
                    if item.grouped > 0 {
                        result.append(DiskTile(nodeID: item.id, rect: box, groupedCount: item.grouped, representedIDs: Array(sorted.dropFirst(count))))
                    } else {
                        cumulativeWeight += item.weight
                        let cumulativeExtra = Int((Double(extraBudget) * cumulativeWeight / total).rounded(.down))
                        let childBudget = 1 + max(0, cumulativeExtra - assignedExtra)
                        assignedExtra = cumulativeExtra
                        descendants.append((item.id, box, depth + 1, childBudget))
                    }
                }
                if vertical {
                    remaining.origin.x += thickness
                    remaining.size.width = max(0, remaining.width - thickness)
                } else {
                    remaining.origin.y += thickness
                    remaining.size.height = max(0, remaining.height - thickness)
                }
                cursor = end
            }
            // Reserve each sibling's share before descending: no branch can starve another.
            pending.append(contentsOf: descendants.reversed())
        }
        // Aggregate subtrees are disjoint, so summarizing them visits each hidden node at most once.
        for index in result.indices {
            if Task.isCancelled { return DiskScene() }
            if !result[index].isAggregate {
                result[index].bytes = snapshot.nodes[result[index].nodeID].bytes(metric)
                continue
            }
            var totals: [DiskFileType: (Int, Int64)] = [:]
            var stack = result[index].representedIDs
            while let id = stack.popLast() {
                if Task.isCancelled { return DiskScene() }
                let node = snapshot.nodes[id]
                if node.isDirectory { stack.append(contentsOf: node.children) }
                else {
                    let old = totals[node.fileType, default: (0, 0)]
                    totals[node.fileType] = (old.0 + 1, old.1 + node.bytes(metric))
                }
            }
            result[index].composition = totals.map { TypeSummary(type: $0.key, count: $0.value.0, bytes: $0.value.1) }
                .sorted { $0.bytes == $1.bytes ? $0.type.rawValue < $1.type.rawValue : $0.bytes > $1.bytes }
            result[index].bytes = result[index].composition.reduce(0) { $0 + $1.bytes }
        }
        return DiskScene(tiles: result, folders: folders)
    }
}
