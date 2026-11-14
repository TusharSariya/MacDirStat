import Foundation
import Darwin

/// Physical Darwin traversal reuses the stat metadata already fetched by FTS.
enum NativeDiskScanner {
    static func scan(_ rootURL: URL, maximumDepth: Int = .max, prepareOrdering: Bool = true, partitionAfter: Int = .max, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanSnapshot {
        let start = Date()
        let root = rootURL.standardizedFileURL
        let identity = try FileIdentity.read(root)
        guard identity.kind == S_IFDIR else { throw DiskScanner.ScanError.notDirectory }
        guard let directory = opendir(root.path) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        closedir(directory)
        let path = strdup(root.path)!
        defer { free(path) }
        var paths: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let tree = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { fts_close(tree) }
        var nodes: [DiskNode] = []
        var issues: [ScanIssue] = []
        var issueCount = 0
        var lastUpdate = Date.distantPast
        var bytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = fts_read(tree) else {
                if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                break
            }
            let value = entry.pointee
            if Int32(value.fts_info) == FTS_D, (Int(value.fts_level) >= maximumDepth || (value.fts_level > 0 && nodes.count >= partitionAfter)) {
                fts_set(tree, entry, FTS_SKIP)
            }
            if Int32(value.fts_info) == FTS_DP { continue }
            let failed = [FTS_ERR, FTS_NS, FTS_DNR, FTS_DC].contains(Int32(value.fts_info))
            let parent: Int? = value.fts_level == 0 ? nil : Int(value.fts_parent.pointee.fts_number)
            if failed {
                issueCount += 1
                if issues.count < 500 {
                    issues.append(ScanIssue(id: issueCount, path: String(cString: value.fts_path),
                        message: NSError(domain: NSPOSIXErrorDomain, code: Int(value.fts_errno == 0 ? ELOOP : value.fts_errno)).localizedDescription))
                }
                if let parent, nodes.indices.contains(parent) { nodes[parent].hasScanError = true }
                // A directory that was already emitted may later be reported unreadable.
                if Int32(value.fts_info) == FTS_DNR {
                    let id = Int(value.fts_number)
                    if nodes.indices.contains(id), nodes[id].url.path == String(cString: value.fts_path) {
                        nodes[id].hasScanError = true
                    }
                    continue
                }
                continue
            }
            guard let stat = value.fts_statp?.pointee else { continue }
            let kind = stat.st_mode & S_IFMT
            let isDirectory = kind == S_IFDIR
            let link = kind == S_IFLNK
            let id = nodes.count
            entry.pointee.fts_number = id
            let url = URL(fileURLWithPath: String(cString: value.fts_path), isDirectory: isDirectory)
            var node = DiskNode(id: id, parent: parent, url: url, isDirectory: isDirectory,
                isSymbolicLink: link, modified: Date(timeIntervalSince1970: Double(stat.st_mtimespec.tv_sec) + Double(stat.st_mtimespec.tv_nsec) / 1e9),
                fileType: link ? .other : DiskFileType.classify(url),
                logicalSize: isDirectory ? 0 : stat.st_size, allocatedSize: isDirectory ? 0 : stat.st_blocks * 512)
            node.identity = FileIdentity(device: stat.st_dev, inode: stat.st_ino, kind: kind)
            nodes.append(node)
            if let parent { nodes[parent].children.append(id) }
            bytes += node.logicalSize
            if id % 256 == 0, Date().timeIntervalSince(lastUpdate) >= 0.1 {
                progress(ScanProgress(count: id, bytes: bytes, path: url.path))
                lastUpdate = Date()
            }
        }
        guard !nodes.isEmpty else { throw DiskScanner.ScanError.cannotEnumerate }
        for id in nodes.indices.reversed() where id != 0 {
            if id % 1024 == 0 { try Task.checkCancellation() }
            let parent = nodes[id].parent!
            nodes[parent].logicalSize += nodes[id].logicalSize
            nodes[parent].allocatedSize += nodes[id].allocatedSize
            nodes[parent].descendantCount += 1 + nodes[id].descendantCount
            nodes[parent].hasScanError = nodes[parent].hasScanError || nodes[id].hasScanError
        }
        nodes[0].hasScanError = issueCount > 0
        if prepareOrdering { try ChildOrdering.prepare(nodes: &nodes) }
        try Task.checkCancellation()
        progress(ScanProgress(count: nodes.count - 1, bytes: nodes[0].logicalSize, path: root.path))
        return ScanSnapshot(nodes: nodes, issues: issues, issueCount: issueCount, elapsed: Date().timeIntervalSince(start), scannedAt: Date())
    }
}
