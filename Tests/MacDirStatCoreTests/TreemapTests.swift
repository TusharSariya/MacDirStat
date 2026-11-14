import XCTest
import CoreGraphics
@testable import MacDirStatCore

final class TreemapTests: XCTestCase {
    private func snapshot(count: Int) -> ScanSnapshot {
        var nodes = [DiskNode(id: 0, parent: nil, url: URL(fileURLWithPath: "/fixture"), isDirectory: true,
            isSymbolicLink: false, modified: nil, fileType: .other, logicalSize: 0, allocatedSize: 0)]
        for id in 1...count {
            nodes.append(DiskNode(id: id, parent: 0, url: URL(fileURLWithPath: "/fixture/\(id)"),
                isDirectory: false, isSymbolicLink: false, modified: nil, fileType: .code,
                logicalSize: Int64(id), allocatedSize: Int64(id)))
            nodes[0].children.append(id)
            nodes[0].logicalSize += Int64(id)
        }
        nodes[0].descendantCount = count
        return ScanSnapshot(nodes: nodes, issues: [], issueCount: 0, elapsed: 0, scannedAt: Date())
    }

    func testAreaAndProportionsWithoutOverlap() {
        let snapshot = snapshot(count: 80)
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let tiles = DiskTreemapLayout.make(snapshot: snapshot, root: 0, metric: .logical, frame: frame)
        XCTAssertEqual(tiles.count, 80)
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.rect.width * $1.rect.height }, 960_000, accuracy: 0.01)
        for (index, tile) in tiles.enumerated() {
            XCTAssertGreaterThan(tile.rect.width, 0)
            XCTAssertGreaterThan(tile.rect.height, 0)
            XCTAssertTrue(frame.insetBy(dx: -0.001, dy: -0.001).contains(tile.rect))
            let fraction = Double(snapshot.nodes[tile.nodeID].logicalSize) / Double(snapshot.root.logicalSize)
            XCTAssertEqual(tile.rect.width * tile.rect.height / 960_000, fraction, accuracy: 0.00001)
            for other in tiles.dropFirst(index + 1) {
                let intersection = tile.rect.intersection(other.rect)
                XCTAssertTrue(intersection.isNull || intersection.width * intersection.height < 0.001)
            }
        }
    }

    func testVeryWideDirectoryIsBoundedAndPreservesTotalArea() {
        let snapshot = snapshot(count: 100_000)
        let start = Date()
        let tiles = DiskTreemapLayout.make(snapshot: snapshot, root: 0, metric: .logical,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 600), limit: 300)
        XCTAssertLessThanOrEqual(tiles.count, 300)
        XCTAssertTrue(tiles.contains { $0.groupedCount > 0 })
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.rect.width * $1.rect.height }, 600_000, accuracy: 0.01)
        print("100,000-node layout: \(Date().timeIntervalSince(start)) seconds, \(tiles.count) tiles")
    }

    func testLargestDirectoryReceivesDetailBeforeSmallSiblings() {
        func node(_ id: Int, _ parent: Int?, _ directory: Bool, _ bytes: Int64) -> DiskNode {
            DiskNode(id: id, parent: parent, url: URL(fileURLWithPath: "/fixture/\(id)"),
                     isDirectory: directory, isSymbolicLink: false, modified: nil,
                     fileType: .other, logicalSize: bytes, allocatedSize: bytes)
        }
        var nodes = [node(0, nil, true, 2_100_000), node(1, 0, true, 2_000_000),
                     node(2, 1, false, 1_000_000), node(3, 1, false, 1_000_000), node(4, 0, true, 100_000)]
        nodes[0].children = [1, 4]
        nodes[1].children = [2, 3]
        nodes[1].descendantCount = 2
        nodes[4].children = Array(5..<105)
        nodes[4].descendantCount = 100
        for id in 5..<105 { nodes.append(node(id, 4, false, 1000)) }
        let snapshot = ScanSnapshot(nodes: nodes, issues: [], issueCount: 0, elapsed: 0, scannedAt: Date())
        let tiles = DiskTreemapLayout.make(snapshot: snapshot, root: 0, metric: .logical,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 700), limit: 10)
        XCTAssertTrue(tiles.contains { $0.nodeID == 2 && $0.groupedCount == 0 })
        XCTAssertTrue(tiles.contains { $0.nodeID == 3 && $0.groupedCount == 0 })
        XCTAssertLessThanOrEqual(tiles.count, 10)
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.rect.width * $1.rect.height }, 700_000, accuracy: 0.01)
    }

    func testSiblingBudgetsAndAggregateComposition() {
        func node(_ id: Int, _ parent: Int?, _ directory: Bool, _ bytes: Int64, _ type: DiskFileType = .code) -> DiskNode {
            DiskNode(id: id, parent: parent, url: URL(fileURLWithPath: "/fixture/\(id)"),
                     isDirectory: directory, isSymbolicLink: false, modified: nil,
                     fileType: type, logicalSize: bytes, allocatedSize: bytes)
        }
        var nodes = [node(0, nil, true, 2000)]
        for _ in 0..<2 {
            let folder = nodes.count
            nodes.append(node(folder, 0, true, 1000))
            nodes[0].children.append(folder)
            for index in 0..<100 {
                let id = nodes.count
                nodes.append(node(id, folder, false, 10, index % 2 == 0 ? .video : .image))
                nodes[folder].children.append(id)
            }
            nodes[folder].descendantCount = 100
        }
        let snapshot = ScanSnapshot(nodes: nodes, issues: [], issueCount: 0, elapsed: 0, scannedAt: Date())
        let scene = DiskTreemapLayout.scene(snapshot: snapshot, root: 0, metric: .logical,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800), limit: 20)
        XCTAssertLessThanOrEqual(scene.tiles.count, 20)
        XCTAssertEqual(scene.tiles.reduce(0) { $0 + $1.bytes }, 2000)
        for folder in nodes[0].children {
            XCTAssertTrue(scene.tiles.contains { !$0.isAggregate && nodes[$0.nodeID].parent == folder })
            let aggregates = scene.tiles.filter { $0.isAggregate && $0.nodeID == folder }
            XCTAssertFalse(aggregates.isEmpty)
            for tile in aggregates {
                XCTAssertEqual(tile.composition.reduce(0) { $0 + $1.bytes }, tile.bytes)
                XCTAssertEqual(tile.composition.reduce(0) { $0 + $1.count }, tile.representedIDs.count)
                XCTAssertEqual(Set(tile.composition.map(\.type)), [.video, .image])
            }
        }
        XCTAssertEqual(scene.tiles.reduce(0) { $0 + $1.rect.width * $1.rect.height }, 960_000, accuracy: 0.01)
    }

    func testDiskImageClassificationAndZeroBudget() {
        XCTAssertEqual(DiskFileType.classify(URL(fileURLWithPath: "/rootfs.img")), .diskImage)
        XCTAssertEqual(DiskFileType.classify(URL(fileURLWithPath: "/Disk.QCOW2")), .diskImage)
        XCTAssertTrue(DiskTreemapLayout.make(snapshot: snapshot(count: 1), root: 0, metric: .logical,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100), limit: 0).isEmpty)
    }

    func testEmptyFrameDoesNotProduceInvalidRectangles() {
        XCTAssertTrue(DiskTreemapLayout.make(snapshot: snapshot(count: 1), root: 0, metric: .logical, frame: .zero).isEmpty)
    }
}
