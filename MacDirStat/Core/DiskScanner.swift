import Foundation

/// Synchronous native scan for tests and callers without a task group.
/// The GUI and helper use ParallelDiskScanner for bounded concurrent traversal.
enum DiskScanner {
    static func scan(_ root: URL, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanSnapshot {
        try NativeDiskScanner.scan(root, progress: progress)
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
