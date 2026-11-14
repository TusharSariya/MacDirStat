import Foundation
import Darwin

@main struct ScannerParity {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let reference = try ReferenceScanner.scan(root)
        let candidate = try await ParallelDiskScanner.scan(root)
        func key(_ url: URL) -> String { url.path.replacingOccurrences(of: "/private/var/", with: "/var/") }
        let expected = Dictionary(uniqueKeysWithValues: reference.nodes.map { (key($0.url), $0) })
        var differences = 0
        for node in candidate.nodes {
            guard let other = expected[key(node.url)],
                  other.logicalSize == node.logicalSize, other.allocatedSize == node.allocatedSize,
                  other.identity == node.identity, other.isDirectory == node.isDirectory,
                  other.isSymbolicLink == node.isSymbolicLink, other.descendantCount == node.descendantCount else {
                differences += 1
                if differences < 12 { print("DIFFERENCE \(node.url.path): candidate \(node.logicalSize)/\(node.allocatedSize), reference \(expected[key(node.url)]?.logicalSize ?? -1)/\(expected[key(node.url)]?.allocatedSize ?? -1)") }
                continue
            }
        }
        print("reference=\(reference.nodes.count) candidate=\(candidate.nodes.count) differences=\(differences) issues=\(reference.issueCount)/\(candidate.issueCount)")
        guard differences == 0, reference.nodes.count == candidate.nodes.count, reference.issueCount == candidate.issueCount else { exit(1) }
    }
}
