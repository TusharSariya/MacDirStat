import Foundation

/// Bounded concurrent subtrees merged back into the depth-first representation used by the UI.
enum ParallelDiskScanner {
    static func scan(_ root: URL, workers: Int = 4, depth: Int = 4,
                     progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> ScanSnapshot {
        let start = Date()
        let seed = try NativeDiskScanner.scan(root, maximumDepth: depth, prepareOrdering: false, partitionAfter: 4096, progress: progress)
        let frontier = seed.nodes.filter { $0.id != 0 && $0.isDirectory && $0.children.isEmpty && !$0.hasScanError }
        if frontier.isEmpty {
            var nodes = seed.nodes
            try ChildOrdering.prepare(nodes: &nodes)
            try Task.checkCancellation()
            return ScanSnapshot(nodes: nodes, issues: seed.issues, issueCount: seed.issueCount,
                elapsed: Date().timeIntervalSince(start), scannedAt: Date())
        }
        let updates = ProgressState(seed: seed, report: progress)
        let workerCount = max(1, min(workers, ProcessInfo.processInfo.activeProcessorCount, 8))
        @Sendable func subtree(_ node: DiskNode) throws -> ScanSnapshot {
            do {
                let result = try NativeDiskScanner.scan(node.url, prepareOrdering: false) { updates.update(node.id, $0) }
                guard result.root.identity == node.identity else { throw DiskScanner.ScanError.invalidTraversal }
                return result
            } catch is CancellationError { throw CancellationError() }
            catch {
                var failed = DiskNode(id: 0, parent: nil, url: node.url, isDirectory: true, isSymbolicLink: false,
                    modified: node.modified, fileType: .other, logicalSize: 0, allocatedSize: 0)
                failed.identity = node.identity
                failed.hasScanError = true
                return ScanSnapshot(nodes: [failed], issues: [ScanIssue(id: 1, path: node.url.path, message: error.localizedDescription)],
                    issueCount: 1, elapsed: 0, scannedAt: Date())
            }
        }
        var replacements: [Int: ScanSnapshot] = [:]
        try await withThrowingTaskGroup(of: (Int, ScanSnapshot).self) { group in
            var next = 0
            for _ in 0..<min(workerCount, frontier.count) {
                let node = frontier[next]; next += 1
                group.addTask { (node.id, try subtree(node)) }
            }
            while let (id, result) = try await group.next() {
                replacements[id] = result
                if next < frontier.count {
                    let node = frontier[next]; next += 1
                    group.addTask { (node.id, try subtree(node)) }
                }
            }
        }
        var nodes: [DiskNode] = []
        nodes.reserveCapacity(seed.nodes.count + replacements.values.reduce(0) { $0 + $1.nodes.count - 1 })
        var pending: [(Int?, Int, Int?)] = [(nil, 0, nil)]
        while let (source, index, parent) = pending.popLast() {
            try Task.checkCancellation()
            if source == nil, replacements[index] != nil {
                pending.append((index, 0, parent)); continue
            }
            let old = source.map { replacements[$0]!.nodes[index] } ?? seed.nodes[index]
            let id = nodes.count
            var node = DiskNode(id: id, parent: parent, url: old.url, isDirectory: old.isDirectory,
                isSymbolicLink: old.isSymbolicLink, modified: old.modified, fileType: old.fileType,
                logicalSize: old.isDirectory ? 0 : old.logicalSize, allocatedSize: old.isDirectory ? 0 : old.allocatedSize, cachedName: old.name)
            node.identity = old.identity
            node.hasScanError = old.hasScanError
            nodes.append(node)
            if let parent { nodes[parent].children.append(id) }
            for child in old.children.reversed() { pending.append((source, child, id)) }
        }
        for id in nodes.indices.reversed() where id != 0 {
            if id % 1024 == 0 { try Task.checkCancellation() }
            let parent = nodes[id].parent!
            nodes[parent].logicalSize += nodes[id].logicalSize
            nodes[parent].allocatedSize += nodes[id].allocatedSize
            nodes[parent].descendantCount += 1 + nodes[id].descendantCount
            nodes[parent].hasScanError = nodes[parent].hasScanError || nodes[id].hasScanError
        }
        try ChildOrdering.prepare(nodes: &nodes)
        let allIssues = seed.issues + frontier.flatMap { replacements[$0.id]?.issues ?? [] }
        let issues = allIssues.prefix(500).enumerated().map { ScanIssue(id: $0.offset + 1, path: $0.element.path, message: $0.element.message) }
        try Task.checkCancellation()
        progress(ScanProgress(count: nodes.count - 1, bytes: nodes[0].logicalSize, path: root.path))
        return ScanSnapshot(nodes: nodes, issues: issues, issueCount: seed.issueCount + replacements.values.reduce(0) { $0 + $1.issueCount }, elapsed: Date().timeIntervalSince(start), scannedAt: Date())
    }
}

/// Worker callbacks share only throttled progress; tree storage is task-local.
private final class ProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int: ScanProgress] = [:]
    private var lastUpdate = Date.distantPast
    private let baseCount: Int
    private let baseBytes: Int64
    private let report: @Sendable (ScanProgress) -> Void
    init(seed: ScanSnapshot, report: @escaping @Sendable (ScanProgress) -> Void) {
        baseCount = seed.nodes.count - 1
        baseBytes = seed.root.logicalSize
        self.report = report
    }
    func update(_ id: Int, _ value: ScanProgress) {
        lock.withLock {
            counts[id] = value
            if Date().timeIntervalSince(lastUpdate) >= 0.1 {
                lastUpdate = Date()
                report(ScanProgress(count: baseCount + counts.values.reduce(0) { $0 + $1.count },
                    bytes: baseBytes + counts.values.reduce(0) { $0 + $1.bytes }, path: value.path))
            }
        }
    }
}
