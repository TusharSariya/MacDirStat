import Foundation
import Darwin

/// Metadata-only traversal. Never follows symbolic links or opens file contents.
/// Call from a background task. Cancellation is checked between filesystem operations.
enum DiskScanner {
    static func scan(
        _ rootURL: URL,
        progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) throws -> ScanSnapshot {
        let start = Date()
        let manager = FileManager()
        let root = rootURL.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey
        ]
        try Task.checkCancellation()
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ScanError.notDirectory
        }
        // Force root access errors to be fatal instead of displaying a misleading empty scan.
        guard let directory = opendir(root.path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        closedir(directory)
        var nodes = [DiskNode(id: 0, parent: nil, url: root, isDirectory: true,
                              isSymbolicLink: false, modified: rootValues.contentModificationDate,
                              fileType: .other, logicalSize: 0, allocatedSize: 0)]
        nodes[0].identity = try FileIdentity.read(root)
        var issues: [ScanIssue] = []
        var issueCount = 0
        var failedPaths = Set<String>()
        func record(_ url: URL, _ error: Error) {
            issueCount += 1
            failedPaths.insert(url.path)
            if issues.count < 500 {
                issues.append(ScanIssue(id: issueCount, path: url.path, message: error.localizedDescription))
            }
        }
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { url, error in
                record(url, error)
                return !Task.isCancelled
            }) else { throw ScanError.cannotEnumerate }
        var parents = [0]
        var byteCount: Int64 = 0
        var lastUpdate = Date.distantPast
        while true {
            try Task.checkCancellation()
            let didRead = try autoreleasepool { () throws -> Bool in
                guard let url = enumerator.nextObject() as? URL else { return false }
                try Task.checkCancellation()
                let level = enumerator.level
                while parents.count > level { parents.removeLast() }
                guard parents.count == level, let parent = parents.last else { throw ScanError.invalidTraversal }
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    let link = values.isSymbolicLink == true
                    let directory = values.isDirectory == true && !link
                    // FileManager already avoids following symlinks. Calling skipDescendants
                    // on a non-directory can instead prune the next directory in the traversal.
                    let logical = directory ? 0 : Int64(values.fileSize ?? 0)
                    let allocated = directory ? 0 : Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                    let identity = try FileIdentity.read(url)
                    let id = nodes.count
                    nodes.append(DiskNode(id: id, parent: parent,
                        url: URL(fileURLWithPath: url.path, isDirectory: directory), isDirectory: directory,
                        isSymbolicLink: link, modified: values.contentModificationDate,
                        fileType: link ? .other : DiskFileType.classify(url),
                        logicalSize: logical, allocatedSize: allocated))
                    nodes[id].identity = identity
                    nodes[parent].children.append(id)
                    if directory { parents.append(id) }
                    byteCount += logical
                } catch {
                    // Only prune a real directory. On a file or symlink, skipDescendants can
                    // affect a later sibling. If type lookup itself fails, let the enumerator
                    // report traversal errors rather than silently skipping another entry.
                    if let identity = try? FileIdentity.read(url), identity.kind == S_IFDIR {
                        enumerator.skipDescendants()
                    }
                    nodes[parent].hasScanError = true
                    record(url, error)
                }
                if Date().timeIntervalSince(lastUpdate) >= 0.1 {
                    progress(ScanProgress(count: nodes.count - 1, bytes: byteCount, path: url.path))
                    lastUpdate = Date()
                }
                return true
            }
            if !didRead { break }
        }
        try Task.checkCancellation()
        for index in nodes.indices where failedPaths.contains(nodes[index].url.path) {
            nodes[index].hasScanError = true
        }
        // Reverse order guarantees children have been aggregated before their parents.
        for index in nodes.indices.reversed() where index != 0 {
            if index % 1024 == 0 { try Task.checkCancellation() }
            let parent = nodes[index].parent!
            nodes[parent].logicalSize += nodes[index].logicalSize
            nodes[parent].allocatedSize += nodes[index].allocatedSize
            nodes[parent].descendantCount += 1 + nodes[index].descendantCount
            nodes[parent].hasScanError = nodes[parent].hasScanError || nodes[index].hasScanError
        }
        nodes[0].hasScanError = issueCount > 0
        try ChildOrdering.prepare(nodes: &nodes)
        try Task.checkCancellation()
        progress(ScanProgress(count: nodes.count - 1, bytes: nodes[0].logicalSize, path: root.path))
        return ScanSnapshot(nodes: nodes, issues: issues, issueCount: issueCount,
                            elapsed: Date().timeIntervalSince(start), scannedAt: Date())
    }

    enum ScanError: LocalizedError {
        case notDirectory, cannotEnumerate, invalidTraversal
        var errorDescription: String? {
            switch self {
            case .notDirectory: return "Choose a folder, rather than a file or symbolic link."
            case .cannotEnumerate: return "This folder could not be read. Check its permissions."
            case .invalidTraversal: return "The folder changed during the scan. Please rescan."
            }
        }
    }
}
