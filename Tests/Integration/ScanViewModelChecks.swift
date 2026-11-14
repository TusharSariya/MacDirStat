import Foundation
import AppKit

/// Exercises the production view model on the main actor without mocking filesystem work.
@main
struct ScanViewModelChecks {
    @MainActor
    static func main() async throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("MacDirStat-model-\(UUID().uuidString)")
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second")
        for root in [first, second] { try manager.createDirectory(at: root, withIntermediateDirectories: true) }
        for i in 0..<3000 { try Data([1]).write(to: first.appendingPathComponent("item-\(i)")) }
        let nested = second.appendingPathComponent("nested")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: nested.appendingPathComponent("inside"))
        try Data([4]).write(to: second.appendingPathComponent("outside"))
        let model = ScanViewModel()
        model.scan(first)
        model.scan(second)
        try await waitForScan(model)
        try require(model.snapshot?.root.name == "second", "Superseded scan published stale data")
        try require(model.snapshot?.root.logicalSize == 4, "Wrong replacement result")
        let snapshot = model.snapshot!
        let folder = snapshot.nodes.first { $0.name == "nested" }!
        let outside = snapshot.nodes.first { $0.name == "outside" }!
        model.zoom(to: folder.id)
        model.selectedID = outside.id
        try require(model.currentRoot == 0, "Selection outside zoom scope stayed invisible")
        model.scan(first)
        model.cancel()
        try await Task.sleep(for: .milliseconds(200))
        try require(!model.isScanning && model.snapshot?.scannedAt == snapshot.scannedAt, "Cancellation replaced the completed result")
        model.scan(base.appendingPathComponent("missing"))
        try await waitForScan(model)
        try require(model.errorMessage != nil, "Missing root did not report failure")
        try require(model.snapshot?.scannedAt == snapshot.scannedAt, "Failed scan discarded previous results")
        try require(model.scanURL?.lastPathComponent == "second", "Rescan target diverged from displayed results")
        model.rescan()
        try await waitForScan(model)
        try require(model.snapshot?.root.name == "second", "Rescan used failed target")
        try require(!model.canTrash, "Scan root was eligible for Trash")
        let refreshedFolder = model.snapshot!.nodes.first { $0.name == "nested" }!
        model.zoom(to: refreshedFolder.id)
        model.selectedID = model.snapshot!.nodes.first { $0.name == "inside" }!.id
        try Data(repeating: 1, count: 20).write(to: nested.appendingPathComponent("inside"))
        model.refreshSelected()
        try await waitForScan(model)
        try require(model.selected?.name == "inside" && model.selected?.logicalSize == 20, "Refresh lost selection or file size")
        try require(model.snapshot!.nodes[model.currentRoot].name == "nested", "Refresh lost directory zoom")
        try require(model.snapshot?.root.logicalSize == 21, "Refresh failed to update ancestor totals")
        try manager.removeItem(at: nested.appendingPathComponent("inside"))
        model.refreshSelected()
        try await waitForScan(model)
        try require(model.selected?.name == "nested" && model.snapshot?.root.logicalSize == 1, "Refresh of removed item failed to select surviving folder")
        let coordinator = FileTreeView.Coordinator(model: model)
        let outline = NSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: .init("name")))
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outline = outline
        coordinator.refresh()
        let rootMenu = coordinator.menu(for: 0)!
        try require(rootMenu.items.last?.isEnabled == false, "Context menu allowed trashing scan root")
        let outsideID = model.snapshot!.nodes.first { $0.name == "outside" }!.id
        let itemMenu = coordinator.menu(for: outline.row(forItem: NSNumber(value: outsideID)))!
        try require(model.selectedID == outsideID && itemMenu.items.last?.isEnabled == true, "Context menu did not target clicked item")
        try require(coordinator.menu(for: -1) == nil, "Empty area produced an item menu")
        model.scan(first)
        let busyMenu = coordinator.menu(for: 0)!
        try require(!busyMenu.items[0].isEnabled && !busyMenu.items[2].isEnabled, "Busy menu allowed refresh or Trash")
        model.cancel()
        try await checkPrivilegeTransport(snapshot: snapshot)
        if ProcessInfo.processInfo.environment["MACDIRSTAT_REQUIRE_SIGNED_TESTS"] == "1" { try await checkSignedXPC() }
        print("PASS: scan lifecycle, refresh totals and selection, context menu targeting and guards, navigation, root protection, privileged transport and invalid authorization rejection")
    }

    static func checkPrivilegeTransport(snapshot: ScanSnapshot) async throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(ElevatedUpdate(progress: nil, snapshot: snapshot))
        let decoded = try PropertyListDecoder().decode(ElevatedUpdate.self, from: data)
        try require(decoded.snapshot?.root.logicalSize == snapshot.root.logicalSize, "Transport changed aggregate size")
        try require(decoded.snapshot?.nodes.map(\.identity) == snapshot.nodes.map(\.identity), "Transport lost file identities")
        try require(decoded.snapshot?.children(of: 0, sortedBy: .name, metric: .logical) == snapshot.children(of: 0, sortedBy: .name, metric: .logical), "Transport lost sort indexes")
        for invalid in ["relative/path", "", "/tmp/\0invalid"] {
            do {
                _ = try ElevatedConfiguration.validate(path: invalid)
                throw NSError(domain: "Checks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid privileged path was accepted"])
            } catch is ElevatedError { }
        }
        for invalidAuthorization in [Data(), Data(repeating: 0, count: 32)] {
            let session = ScanSession()
            let error: String? = await withCheckedContinuation { continuation in
                session.startScan(path: snapshot.root.url.path, authorization: invalidAuthorization) { continuation.resume(returning: $0) }
            }
            try require(error != nil, "Helper accepted missing OS authorization")
            let response: (Data?, Bool, String?) = await withCheckedContinuation { continuation in
                session.poll { continuation.resume(returning: ($0, $1, $2)) }
            }
            try require(response.0 == nil && response.1 && response.2 != nil, "Unauthorized helper returned scan data")
            session.stop()
        }

    }

    static func checkSignedXPC() async throws {
        let good = try PeerSigning.requirement(identifier: "tushar.MacDirStat.ProtocolChecks")
        let bad = try PeerSigning.requirement(identifier: "tushar.MacDirStat.WrongPeer")
        let accepted = await probeXPC(clientRequirement: good, serverRequirement: good)
        try require(accepted, "Valid signed XPC peers could not communicate")
        let rejectedClient = await probeXPC(clientRequirement: bad, serverRequirement: good)
        try require(!rejectedClient, "Listener accepted the wrong client identity")
        let rejectedServer = await probeXPC(clientRequirement: good, serverRequirement: bad)
        try require(!rejectedServer, "Client accepted the wrong helper identity")
        print("PASS: signed XPC exchange and mutual rejection of wrong peer identifiers")
    }

    static func probeXPC(clientRequirement: String, serverRequirement: String) async -> Bool {
        let listener = NSXPCListener.anonymous()
        let delegate = ListenerDelegate(clientRequirement: clientRequirement)
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(clientRequirement)
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: ElevatedScannerProtocol.self)
        connection.setCodeSigningRequirement(serverRequirement)
        connection.resume()
        defer {
            connection.invalidate()
            listener.invalidate()
            withExtendedLifetime(delegate) {}
        }
        return await withCheckedContinuation { continuation in
            // A checked reply gate ensures timeout/invalidation and a reply cannot resume twice.
            let gate = TestReply(continuation)
            connection.invalidationHandler = { gate.finish(false) }
            connection.interruptionHandler = { gate.finish(false) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { gate.finish(false) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in gate.finish(false) }) as? any ElevatedScannerProtocol else {
                gate.finish(false); return
            }
            proxy.poll { data, finished, error in
                gate.finish(data == nil && finished && error == "No scan has been requested.")
            }
        }
    }

    @MainActor
    static func waitForScan(_ model: ScanViewModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isScanning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try require(!model.isScanning, "Scan did not finish before the test deadline")
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ScanViewModelChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}

private final class TestReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) {
        let pending = lock.withLock {
            let result = continuation
            continuation = nil
            return result
        }
        pending?.resume(returning: value)
    }
}
