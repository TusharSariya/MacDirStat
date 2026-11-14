import Foundation
import Darwin

/// Prototype only: evaluates bulk metadata; not used by the app.
enum BulkScannerExperiment {
    struct Entry {
        let path: String
        let kind: UInt16
        let identity: FileIdentity
        let modified: Date
        let logical: Int64
        let allocated: Int64
    }
    static func statEntry(_ path: String) throws -> Entry {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Entry(path: path, kind: info.st_mode & S_IFMT,
            identity: FileIdentity(device: info.st_dev, inode: info.st_ino, kind: info.st_mode & S_IFMT),
            modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
            logical: info.st_size, allocated: info.st_blocks * 512)
    }
    static func children(_ path: String) throws -> [Entry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = ATTR_CMN_RETURNED_ATTRS | UInt32(ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID)
        attrs.fileattr = UInt32(ATTR_FILE_DATALENGTH | ATTR_FILE_ALLOCSIZE)
        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        var result: [Entry] = []
        while true {
            try Task.checkCancellation()
            let count = getattrlistbulk(fd, &attrs, buffer, capacity, UInt64(FSOPT_PACK_INVAL_ATTRS))
            guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if count == 0 { return result }
            var offset = 0
            for _ in 0..<count {
                guard offset + 84 <= capacity else { throw DiskScanner.ScanError.invalidTraversal }
                let p = buffer.advanced(by: offset)
                let length = Int(p.loadUnaligned(as: UInt32.self))
                guard length >= 68, offset + length <= capacity else { throw DiskScanner.ScanError.invalidTraversal }
                let returned = p.advanced(by: 4).loadUnaligned(as: attribute_set_t.self)
                let error = p.advanced(by: 24).loadUnaligned(as: UInt32.self)
                let reference = p.advanced(by: 28).loadUnaligned(as: attrreference_t.self)
                let nameStart = 28 + Int(reference.attr_dataoffset)
                let nameLength = Int(reference.attr_length)
                guard nameStart >= 68, nameLength > 0, nameStart + nameLength <= length else { throw DiskScanner.ScanError.invalidTraversal }
                let name = String(decoding: UnsafeRawBufferPointer(start: p.advanced(by: nameStart), count: nameLength - 1), as: UTF8.self)
                let child = path + "/" + name
                if error != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
                let type = p.advanced(by: 40).loadUnaligned(as: UInt32.self)
                let kinds: [UInt16] = [0, UInt16(S_IFREG), UInt16(S_IFDIR), UInt16(S_IFBLK), UInt16(S_IFCHR), UInt16(S_IFLNK), UInt16(S_IFSOCK), UInt16(S_IFIFO)]
                let commonRequired = attrs.commonattr & ~UInt32(ATTR_CMN_ERROR)
                if type >= kinds.count || returned.commonattr & commonRequired != commonRequired ||
                    (type != 2 && returned.fileattr & attrs.fileattr != attrs.fileattr) || type == 2 {
                    result.append(try statEntry(child))
                } else {
                    let kind = kinds[Int(type)]
                    let time = p.advanced(by: 44).loadUnaligned(as: timespec.self)
                    result.append(Entry(path: child, kind: kind,
                        identity: FileIdentity(device: p.advanced(by: 36).loadUnaligned(as: Int32.self), inode: p.advanced(by: 60).loadUnaligned(as: UInt64.self), kind: kind),
                        modified: Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9),
                        logical: p.advanced(by: 76).loadUnaligned(as: Int64.self), allocated: p.advanced(by: 68).loadUnaligned(as: Int64.self)))
                }
                offset += length
            }
        }
    }
    static func scan(_ root: URL) throws -> ScanSnapshot {
        let start = Date()
        let first = try statEntry(root.path)
        guard first.kind == S_IFDIR else { throw DiskScanner.ScanError.notDirectory }
        var pending: [(Entry, Int?)] = [(first, nil)]
        var nodes: [DiskNode] = []
        while let (entry, parent) = pending.popLast() {
            try Task.checkCancellation()
            let directory = entry.kind == S_IFDIR
            let link = entry.kind == S_IFLNK
            let id = nodes.count
            let url = URL(fileURLWithPath: entry.path, isDirectory: directory)
            var node = DiskNode(id: id, parent: parent, url: url, isDirectory: directory, isSymbolicLink: link,
                modified: entry.modified, fileType: link ? .other : DiskFileType.classify(url), logicalSize: directory ? 0 : entry.logical, allocatedSize: directory ? 0 : entry.allocated)
            node.identity = entry.identity
            nodes.append(node)
            if let parent { nodes[parent].children.append(id) }
            if directory { for child in try children(entry.path).reversed() { pending.append((child, id)) } }
        }
        for id in nodes.indices.reversed() where id != 0 {
            let parent = nodes[id].parent!
            nodes[parent].logicalSize += nodes[id].logicalSize
            nodes[parent].allocatedSize += nodes[id].allocatedSize
            nodes[parent].descendantCount += 1 + nodes[id].descendantCount
        }
        try ChildOrdering.prepare(nodes: &nodes)
        return ScanSnapshot(nodes: nodes, issues: [], issueCount: 0, elapsed: Date().timeIntervalSince(start), scannedAt: Date())
    }
}
