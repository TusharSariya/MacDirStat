import XCTest
@testable import MacDirStatCore

final class FileActionsTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacDirStat-actions-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testRejectsRootAndReplacedFile() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("file")
        try Data([1]).write(to: file)
        let snapshot = try DiskScanner.scan(root)
        let id = try XCTUnwrap(snapshot.nodes.first { $0.name == "file" }).id
        XCTAssertThrowsError(try FileActions.validateTrash(snapshot: snapshot, nodeID: 0))
        XCTAssertEqual(try FileIdentity.read(FileActions.validateTrash(snapshot: snapshot, nodeID: id)), try FileIdentity.read(file))
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("original"))
        try Data([2]).write(to: file)
        XCTAssertThrowsError(try FileActions.validateTrash(snapshot: snapshot, nodeID: id))
        XCTAssertEqual(try Data(contentsOf: file), Data([2]))
    }

    func testRejectsAncestorReplacedWithSymbolicLink() throws {
        let root = try fixture()
        let child = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let file = child.appendingPathComponent("file")
        try Data([1]).write(to: file)
        let snapshot = try DiskScanner.scan(root)
        let id = try XCTUnwrap(snapshot.nodes.first { $0.name == "file" }).id
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: child, to: moved)
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: moved)
        XCTAssertThrowsError(try FileActions.validateTrash(snapshot: snapshot, nodeID: id))
        XCTAssertEqual(try Data(contentsOf: file), Data([1]))
    }

    func testNativeTrashAndRestoreOnlyDisposableFixture() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("MacDirStat-disposable-\(UUID().uuidString).txt")
        let payload = Data("Disposable MacDirStat test fixture".utf8)
        try payload.write(to: file)
        let snapshot = try DiskScanner.scan(root)
        let id = try XCTUnwrap(snapshot.nodes.first { $0.name == file.lastPathComponent }).id
        let trashed = try FileActions.trash(snapshot: snapshot, nodeID: id)
        // Always restore this test-created file; normal teardown then removes the fixture.
        defer { if !FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.moveItem(at: trashed, to: file) } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: trashed), payload)
        try FileManager.default.moveItem(at: trashed, to: file)
        XCTAssertEqual(try Data(contentsOf: file), payload)
    }

    func testTrashingSymlinkDoesNotTrashTarget() throws {
        let root = try fixture()
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try Data([1, 2, 3]).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let snapshot = try DiskScanner.scan(root)
        let id = try XCTUnwrap(snapshot.nodes.first { $0.name == "link" }).id
        let trashed = try FileActions.trash(snapshot: snapshot, nodeID: id)
        defer { try? FileManager.default.moveItem(at: trashed, to: link) }
        XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: trashed.path), target.path)
    }
}
