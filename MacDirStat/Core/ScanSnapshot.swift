import Foundation

/// A scan is immutable after publication. Integer IDs are indexes into `nodes`.
struct ScanSnapshot: Sendable, Codable {
    let nodes: [DiskNode]
    let issues: [ScanIssue]
    let issueCount: Int
    let elapsed: TimeInterval
    let scannedAt: Date

    var root: DiskNode { nodes[0] }

    func ancestors(of id: Int) -> [Int] {
        var result: [Int] = []
        var current: Int? = id
        while let index = current {
            result.append(index)
            current = nodes[index].parent
        }
        return result.reversed()
    }

    func children(of id: Int, sortedBy sort: DiskSort, metric: SizeMetric) -> [Int] {
        if let order = nodes[id].ordering {
            switch (sort, metric) {
            case (.name, _): return order.name
            case (.size, .logical): return order.logical
            case (.size, .allocated): return order.allocated
            }
        }
        return nodes[id].children.sorted {
            let a = nodes[$0], b = nodes[$1]
            if sort == .size, a.bytes(metric) != b.bytes(metric) {
                return a.bytes(metric) > b.bytes(metric)
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func typeSummary(metric: SizeMetric) -> [TypeSummary] {
        var totals: [DiskFileType: (Int, Int64)] = [:]
        for node in nodes where !node.isDirectory {
            let old = totals[node.fileType, default: (0, 0)]
            totals[node.fileType] = (old.0 + 1, old.1 + node.bytes(metric))
        }
        return totals.map { TypeSummary(type: $0.key, count: $0.value.0, bytes: $0.value.1) }
            .sorted { $0.bytes > $1.bytes }
    }
}

enum SizeMetric: String, CaseIterable, Identifiable, Sendable, Codable {
    case logical = "File size", allocated = "Size on disk"
    var id: Self { self }
}

enum DiskSort: String, CaseIterable, Identifiable, Sendable, Codable {
    case size = "Size", name = "Name"
    var id: Self { self }
}

struct DiskNode: Identifiable, Sendable, Codable {
    let id: Int
    let parent: Int?
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let modified: Date?
    let fileType: DiskFileType
    var logicalSize: Int64
    var allocatedSize: Int64
    var identity: FileIdentity? = nil
    var ordering: ChildOrdering? = nil
    var children: [Int] = []
    var descendantCount = 0
    var hasScanError = false
    let name: String

    init(id: Int, parent: Int?, url: URL, isDirectory: Bool, isSymbolicLink: Bool,
         modified: Date?, fileType: DiskFileType, logicalSize: Int64, allocatedSize: Int64, cachedName: String? = nil) {
        self.id = id
        self.parent = parent
        self.url = url
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.modified = modified
        self.fileType = fileType
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        if let cachedName { self.name = cachedName }
        else {
            let component = url.lastPathComponent
            self.name = component.isEmpty ? url.path : component
        }
    }
    func bytes(_ metric: SizeMetric) -> Int64 { metric == .logical ? logicalSize : allocatedSize }
}

struct ScanIssue: Identifiable, Sendable, Codable {
    let id: Int
    let path: String
    let message: String
}

struct ScanProgress: Sendable, Codable {
    let count: Int
    let bytes: Int64
    let path: String
}

struct TypeSummary: Identifiable, Sendable, Codable {
    let type: DiskFileType
    let count: Int
    let bytes: Int64
    var id: DiskFileType { type }
}

enum DiskFileType: String, CaseIterable, Sendable, Codable {
    case video, audio, image, document, code, archive, diskImage, other

    static func classify(_ url: URL) -> Self {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "mkv", "avi", "webm", "m4v": return .video
        case "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg": return .audio
        case "jpg", "jpeg", "png", "gif", "heic", "tiff", "webp", "raw", "cr2", "svg": return .image
        case "pdf", "txt", "md", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "epub": return .document
        case "swift", "m", "h", "c", "cpp", "rs", "go", "js", "ts", "tsx", "jsx", "py", "rb", "java", "json", "html", "css", "yaml", "yml", "sh": return .code
        case "zip", "gz", "tar", "bz2", "xz", "7z", "rar", "xip", "pkg": return .archive
        case "img", "dmg", "iso", "qcow2", "vhd", "vhdx", "vmdk", "sparseimage", "sparsebundle": return .diskImage
        default: return .other
        }
    }
}

/// Computed by the scanner, so expanding/sorting a large folder does no comparison work on the UI thread.
struct ChildOrdering: Sendable, Codable {
    let name: [Int]
    let logical: [Int]
    let allocated: [Int]

    static func prepare(nodes: inout [DiskNode]) throws {
        for id in nodes.indices where !nodes[id].children.isEmpty {
            try Task.checkCancellation()
            let ordering = try autoreleasepool { () throws -> ChildOrdering in
                var comparisons = 0
                func checkpoint() throws {
                    comparisons += 1
                    if comparisons % 2048 == 0 { try Task.checkCancellation() }
                }
                let names = try nodes[id].children.sorted {
                    try checkpoint()
                    let comparison = nodes[$0].name.localizedStandardCompare(nodes[$1].name)
                    return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
                }
                try Task.checkCancellation()
                // Stable tie-breaking by name rank avoids localized comparisons for equal sizes.
                let ranks = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
                func sorted(_ metric: SizeMetric) throws -> [Int] {
                    try names.sorted {
                        try checkpoint()
                        let a = nodes[$0].bytes(metric), b = nodes[$1].bytes(metric)
                        return a == b ? ranks[$0]! < ranks[$1]! : a > b
                    }
                }
                let logical = try sorted(.logical)
                let allocated = try sorted(.allocated)
                return ChildOrdering(name: names, logical: logical, allocated: allocated)
            }
            nodes[id].ordering = ordering
        }
    }
}
