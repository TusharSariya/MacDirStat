import Foundation
import CoreGraphics

struct DiskTile: Sendable {
    let nodeID: Int
    let rect: CGRect
    var groupedCount = 0
}

/// Squarified layout with bounded detail. Subpixel directories are represented by one tile.
/// Very wide directories group their smallest items; the outline still exposes every file.
enum DiskTreemapLayout {
    static func make(snapshot: ScanSnapshot, root: Int, metric: SizeMetric, frame: CGRect,
                     limit: Int = 6000) -> [DiskTile] {
        guard frame.width > 0, frame.height > 0, snapshot.nodes[root].bytes(metric) > 0 else { return [] }
        var result: [DiskTile] = []
        var pending: [(Int, CGRect, Int)] = [(root, frame, 0)]
        while let (id, rect, depth) = pending.popLast() {
            if Task.isCancelled { return [] }
            let node = snapshot.nodes[id]
            if !node.isDirectory || node.children.isEmpty || rect.width < 5 || rect.height < 5 || depth >= 64 {
                result.append(DiskTile(nodeID: id, rect: rect))
                continue
            }
            let available = max(1, limit - result.count - pending.count)
            let sorted = snapshot.children(of: id, sortedBy: .size, metric: metric)
                .filter { snapshot.nodes[$0].bytes(metric) > 0 }
            guard !sorted.isEmpty else { continue }
            if available < 2 {
                result.append(DiskTile(nodeID: id, rect: rect, groupedCount: node.descendantCount))
                continue
            }
            let count = min(sorted.count, min(available - 1, 1500))
            var weights = sorted.prefix(count).map { (id: $0, weight: Double(snapshot.nodes[$0].bytes(metric)), grouped: 0) }
            if count < sorted.count {
                let remaining = sorted.dropFirst(count)
                let bytes = remaining.reduce(0.0) { $0 + Double(snapshot.nodes[$1].bytes(metric)) }
                weights.append((id, bytes, remaining.count))
            }
            let total = weights.reduce(0) { $0 + $1.weight }
            let scale = rect.width * rect.height / total
            var remaining = rect
            var descendants: [(Int, CGRect, Int)] = []
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
                        result.append(DiskTile(nodeID: item.id, rect: box, groupedCount: item.grouped))
                    } else { descendants.append((item.id, box, depth + 1)) }
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
            // The stack is LIFO: reverse the size-sorted work so large folders receive
            // detail before tiny siblings consume the drawing budget.
            pending.append(contentsOf: descendants.reversed())
        }
        return result
    }
}
