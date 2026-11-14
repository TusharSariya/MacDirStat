import XCTest
import Darwin
@testable import MacDirStatCore

final class ParallelScannerTests: XCTestCase {
    func testParallelMatchesSerialAndPreservesDepthFirstIntervals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for branch in 0..<12 {
            let directory = root.appendingPathComponent("branch-\(branch)/a/b/c")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in 0..<20 { try Data(repeating: 1, count: file * 10).write(to: directory.appendingPathComponent("\(file).txt")) }
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("cycle").path, withDestinationPath: root.path)
        let serial = try DiskScanner.scan(root)
        for workers in [1, 2, 4, 8] {
            let parallel = try await ParallelDiskScanner.scan(root, workers: workers)
            XCTAssertEqual(serial.nodes.count, parallel.nodes.count)
            XCTAssertEqual(serial.root.logicalSize, parallel.root.logicalSize)
            XCTAssertEqual(serial.root.allocatedSize, parallel.root.allocatedSize)
            let expected = Dictionary(uniqueKeysWithValues: serial.nodes.map { ($0.url.path, $0) })
            for node in parallel.nodes {
                let other = try XCTUnwrap(expected[node.url.path])
                XCTAssertEqual(node.identity, other.identity)
                XCTAssertEqual(node.logicalSize, other.logicalSize)
                XCTAssertEqual(node.allocatedSize, other.allocatedSize)
                XCTAssertEqual(node.descendantCount, other.descendantCount)
                if node.isDirectory {
                    for id in (node.id + 1)..<(node.id + 1 + node.descendantCount) {
                        XCTAssertTrue(parallel.ancestors(of: id).contains(node.id))
                    }
                }
            }
        }
        do {
            _ = try await ParallelDiskScanner.scan(root) { progress in
                if progress.path.hasSuffix("/c") { withUnsafeCurrentTask { $0?.cancel() } }
            }
            XCTFail("Cancellation inside an active subtree was ignored")
        } catch is CancellationError { }
    }

    func testPartialPermissionsAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data([1]).write(to: locked.appendingPathComponent("hidden"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        let partial = try await ParallelDiskScanner.scan(root)
        XCTAssertGreaterThan(partial.issueCount, 0)
        XCTAssertTrue(partial.root.hasScanError)
        XCTAssertEqual(partial.root.logicalSize, 0)
        let task = Task { try await ParallelDiskScanner.scan(root) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled scan returned a snapshot") }
        catch is CancellationError { }
    }

    func testResourceForkAllocationMatchesFoundation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("forked")
        try Data(repeating: 1, count: 100_000).write(to: file)
        try Data(repeating: 2, count: 150_000).write(to: URL(fileURLWithPath: file.path + "/..namedfork/rsrc"))
        let expected = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        let result = try DiskScanner.scan(root)
        XCTAssertEqual(result.root.logicalSize, Int64(expected.fileSize!))
        XCTAssertEqual(result.root.allocatedSize, Int64(expected.totalFileAllocatedSize!))
    }
}
