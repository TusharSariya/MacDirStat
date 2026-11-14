import Foundation

/// Native Trash is recoverable. Never substitutes permanent deletion or elevated deletion.
enum FileActions {
    static func validateTrash(snapshot: ScanSnapshot, nodeID: Int) throws -> URL {
        guard nodeID != 0, snapshot.nodes.indices.contains(nodeID) else { throw ActionError.scanRoot }
        // Refuse stale entries and directories replaced by symlinks since the scan.
        // The final item itself may be a symlink: lstat checks the link, not its target.
        for id in snapshot.ancestors(of: nodeID) {
            let node = snapshot.nodes[id]
            guard let expected = node.identity,
                  try FileIdentity.read(node.url) == expected else { throw ActionError.changed }
        }
        return snapshot.nodes[nodeID].url
    }

    static func trash(snapshot: ScanSnapshot, nodeID: Int) throws -> URL {
        let url = try validateTrash(snapshot: snapshot, nodeID: nodeID)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL else { throw ActionError.missingResult }
        return resultingURL as URL
    }

    enum ActionError: LocalizedError {
        case scanRoot, changed, missingResult
        var errorDescription: String? {
            switch self {
            case .scanRoot: return "The scanned root cannot be moved to the Trash."
            case .changed: return "This item or an enclosing folder changed since the scan. Rescan before moving it to the Trash."
            case .missingResult: return "The system moved the item but did not return its Trash location. Check the Trash in Finder."
            }
        }
    }
}
