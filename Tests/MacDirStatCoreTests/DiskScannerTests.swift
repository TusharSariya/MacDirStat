import XCTest
import Darwin
@testable import MacDirStatCore

final class DiskScannerTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testNestedHiddenPackageAndEmptySizes() throws {
        let root = try fixture()
        let nested = root.appendingPathComponent("Example.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1234).write(to: nested.appendingPathComponent("code.swift"))
        try Data(repeating: 2, count: 567).write(to: root.appendingPathComponent(".hidden"))
        try Data().write(to: root.appendingPathComponent("empty"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty-folder"), withIntermediateDirectories: true)
        let result = try DiskScanner.scan(root)
        XCTAssertEqual(result.root.logicalSize, 1801)
        XCTAssertEqual(result.root.descendantCount, 6)
        XCTAssertEqual(result.nodes.count, 7)
        XCTAssertEqual(result.issueCount, 0)
        let code = try XCTUnwrap(result.nodes.first { $0.name == "code.swift" })
        XCTAssertEqual(code.fileType, .code)
        XCTAssertEqual(result.ancestors(of: code.id).count, 4)
        XCTAssertEqual(result.typeSummary(metric: .logical).reduce(0) { $0 + $1.bytes }, 1801)
        for node in result.nodes where node.isDirectory {
            XCTAssertEqual(node.logicalSize, node.children.reduce(0) { $0 + result.nodes[$1].logicalSize })
            XCTAssertEqual(node.allocatedSize, node.children.reduce(0) { $0 + result.nodes[$1].allocatedSize })
        }
    }

    func testSymlinksNeverFollowedIncludingCyclesAndOutsideRoot() throws {
        let root = try fixture()
        let outside = try fixture()
        try Data(repeating: 0, count: 5000).write(to: outside.appendingPathComponent("outside-file"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("broken").path, withDestinationPath: "/not-a-real-target-1234")
        let result = try DiskScanner.scan(root)
        XCTAssertEqual(result.nodes.count, 4)
        XCTAssertTrue(result.nodes.dropFirst().allSatisfy { $0.isSymbolicLink && !$0.isDirectory && $0.children.isEmpty })
        XCTAssertThrowsError(try DiskScanner.scan(root.appendingPathComponent("outside")))
    }

    func testLinkSizesDescribeTheLinkNotItsTarget() throws {
        let root = try fixture()
        let outside = try fixture()
        let target = outside.appendingPathComponent("large-target")
        try Data(repeating: 0, count: 100_000).write(to: target)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var info = stat()
        XCTAssertEqual(lstat(link.path, &info), 0)
        let snapshot = try DiskScanner.scan(root)
        XCTAssertEqual(snapshot.root.logicalSize, Int64(info.st_size))
        XCTAssertLessThan(snapshot.root.logicalSize, 100_000)
    }

    func testHardLinksAreCountedPerPathname() throws {
        let root = try fixture()
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try Data([1, 2, 3, 4]).write(to: first)
        try FileManager.default.linkItem(at: first, to: second)
        let snapshot = try DiskScanner.scan(root)
        XCTAssertEqual(snapshot.root.logicalSize, 8)
        XCTAssertEqual(snapshot.nodes.count, 3)
        XCTAssertEqual(snapshot.nodes[1].identity, snapshot.nodes[2].identity)
    }

    func testNamedPipeIsMeasuredWithoutOpeningIt() throws {
        let root = try fixture()
        let pipe = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let snapshot = try DiskScanner.scan(root)
        XCTAssertEqual(snapshot.nodes.count, 2)
        XCTAssertEqual(snapshot.root.logicalSize, 0)
    }

    func testLinksDoNotPruneSiblingFilesOrFolders() throws {
        let root = try fixture()
        for index in 0..<100 {
            let directory = root.appendingPathComponent("folder-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appendingPathComponent("before"))
            try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path, withDestinationPath: "before")
            try Data([2, 3]).write(to: directory.appendingPathComponent("after"))
            let nested = directory.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data([4, 5, 6]).write(to: nested.appendingPathComponent("last"))
        }
        let snapshot = try DiskScanner.scan(root)
        XCTAssertEqual(snapshot.nodes.count, 601)
        XCTAssertEqual(snapshot.root.logicalSize, 1200)
        XCTAssertEqual(snapshot.issueCount, 0)
    }

    func testMissingRootFailsRatherThanReturningEmptySuccess() throws {
        let root = try fixture().appendingPathComponent("missing")
        XCTAssertThrowsError(try DiskScanner.scan(root))
    }

    func testCancellationDuringTraversal() async throws {
        let root = try fixture()
        for i in 0..<100 { try Data([1]).write(to: root.appendingPathComponent("file-\(i)")) }
        let task = Task.detached {
            try DiskScanner.scan(root) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled scan must not publish a completed snapshot")
        } catch is CancellationError {
        }
    }

    func testUnreadableSubfolderProducesPartialResultAndIssue() throws {
        let root = try fixture()
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: locked.appendingPathComponent("hidden"))
        try Data([4, 5]).write(to: root.appendingPathComponent("readable"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let result = try DiskScanner.scan(root)
        XCTAssertEqual(result.root.logicalSize, 2)
        XCTAssertGreaterThan(result.issueCount, 0)
        XCTAssertTrue(result.root.hasScanError)
        XCTAssertTrue(try XCTUnwrap(result.nodes.first { $0.name == "locked" }).hasScanError)
        XCTAssertThrowsError(try DiskScanner.scan(locked))
    }

    func testSparseFileDistinguishesLogicalAndAllocatedBytes() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("sparse.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 8_388_608)
        try handle.close()
        let result = try DiskScanner.scan(root)
        XCTAssertEqual(result.root.logicalSize, 8_388_608)
        XCTAssertLessThan(result.root.allocatedSize, result.root.logicalSize)
    }

    func testReadOnlyPerformanceProbe() throws {
        guard let path = ProcessInfo.processInfo.environment["MACDIRSTAT_BENCHMARK_PATH"] else {
            throw XCTSkip("Set MACDIRSTAT_BENCHMARK_PATH to benchmark an existing tree without changing it")
        }
        let snapshot = try DiskScanner.scan(URL(fileURLWithPath: path).resolvingSymlinksInPath())
        let lookupStart = Date()
        for _ in 0..<1000 {
            _ = snapshot.children(of: 0, sortedBy: .size, metric: .logical)
            _ = snapshot.children(of: 0, sortedBy: .name, metric: .allocated)
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("BENCHMARK nodes=\(snapshot.nodes.count) logicalBytes=\(snapshot.root.logicalSize) seconds=\(snapshot.elapsed) peakRSSBytes=\(usage.ru_maxrss) cachedLookupSeconds=\(Date().timeIntervalSince(lookupStart)) issues=\(snapshot.issueCount)")
        XCTAssertFalse(snapshot.nodes.isEmpty)
        XCTAssertNotNil(snapshot.root.identity)
        if let expected = ProcessInfo.processInfo.environment["MACDIRSTAT_EXPECT_NODES"].flatMap(Int.init) {
            XCTAssertEqual(snapshot.nodes.count, expected, "Entry count differs from the independent lstat walk")
        }
        if let expected = ProcessInfo.processInfo.environment["MACDIRSTAT_EXPECT_BYTES"].flatMap(Int64.init) {
            XCTAssertEqual(snapshot.root.logicalSize, expected, "Logical bytes differ from the independent lstat walk")
        }
    }

    func testWideDirectoryTotalsAndSorting() throws {
        let root = try fixture()
        for i in 0..<2000 {
            try Data(repeating: 0, count: i % 100).write(to: root.appendingPathComponent("file-\(i).txt"))
        }
        let result = try DiskScanner.scan(root)
        XCTAssertEqual(result.root.logicalSize, 99_000)
        XCTAssertEqual(result.root.descendantCount, 2000)
        let ids = result.children(of: 0, sortedBy: .size, metric: .logical)
        XCTAssertEqual(result.nodes[ids[0]].logicalSize, 99)
        XCTAssertEqual(result.nodes[ids.last!].logicalSize, 0)
        print("Scanned 2,000 files in \(result.elapsed) seconds")
    }
}
