import ServiceManagement
import AppKit
import UniformTypeIdentifiers
import Combine

@MainActor
final class ScanViewModel: ObservableObject {
    @Published private(set) var snapshot: ScanSnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var progress = ScanProgress(count: 0, bytes: 0, path: "")
    @Published var selectedID: Int? {
        didSet {
            guard let snapshot, let selectedID, snapshot.nodes.indices.contains(selectedID),
                  snapshot.nodes.indices.contains(currentRoot) else { return }
            if !snapshot.ancestors(of: selectedID).contains(currentRoot) {
                currentRoot = snapshot.nodes[selectedID].parent ?? 0
            }
        }
    }
    @Published private(set) var isFileOperation = false
    @Published var currentRoot = 0
    @Published var metric: SizeMetric = .logical
    @Published private(set) var logicalSummary: [TypeSummary] = []
    @Published private(set) var allocatedSummary: [TypeSummary] = []
    var summary: [TypeSummary] { metric == .logical ? logicalSummary : allocatedSummary }
    @Published var sort: DiskSort = .size
    @Published var errorMessage: String?
    @Published var status = "Choose a folder to see what is using its space."
    @Published var showIssues = false
    @Published var showAccessSettings = false
    @Published private(set) var helperStatus = ElevatedService.statusDescription
    @Published private(set) var resultIsElevated = false
    private(set) var lastRequestedURL: URL?
    private var scanTask: Task<Void, Never>?
    private var generation = UUID()
    private(set) var scanURL: URL?

    var selected: DiskNode? {
        guard let snapshot, let selectedID, snapshot.nodes.indices.contains(selectedID) else { return nil }
        return snapshot.nodes[selectedID]
    }
    var canTrash: Bool { selected != nil && selectedID != 0 && !isScanning && !isFileOperation }

    func openFolder() {
        guard !isFileOperation else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        // App bundles are packages in the picker, even though they are directories on disk.
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.directory]
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan Folder"
        panel.message = "Scan file sizes without reading file contents. Hidden files and app contents are included."
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.scan(url) }
        }
    }

    func scan(_ url: URL, elevated: Bool = false, preservingView: Bool = false) {
        guard !isFileOperation else { return }
        let selectedURL = preservingView ? selected?.url : nil
        let zoomURL = preservingView ? snapshot?.nodes[currentRoot].url : nil
        cancel()
        lastRequestedURL = url
        if snapshot == nil { scanURL = url }
        let token = UUID()
        generation = token
        isScanning = true
        progress = ScanProgress(count: 0, bytes: 0, path: url.path)
        status = "Scanning…"
        let channel = AsyncStream<ScanProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let worker = Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
                channel.continuation.finish()
            }
            let snapshot: ScanSnapshot
            if elevated {
                snapshot = try await ElevatedScanClient.scan(url) { channel.continuation.yield($0) }
            } else {
                snapshot = try DiskScanner.scan(url) { channel.continuation.yield($0) }
            }
            return (snapshot, snapshot.typeSummary(metric: .logical), snapshot.typeSummary(metric: .allocated))
        }
        scanTask = Task { [weak self] in
            await withTaskCancellationHandler {
                for await value in channel.stream {
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    self.progress = value
                }
                do {
                    let (result, logical, allocated) = try await worker.value
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.resultIsElevated = elevated
                    self.scanURL = url
                    self.snapshot = result
                    self.logicalSummary = logical
                    self.allocatedSummary = allocated
                    self.currentRoot = result.nodes.first { $0.url == zoomURL }?.id ?? 0
                    self.selectedID = result.nodes.first { $0.url == selectedURL }?.id ?? self.currentRoot
                    self.status = "\(result.root.descendantCount.formatted()) items · \(String(format: "%.2f", result.elapsed)) seconds"
                    self.isScanning = false
                } catch is CancellationError {
                    guard let self, self.generation == token else { return }
                    self.isScanning = false
                    self.status = "Scan cancelled. Previous results, if any, are unchanged."
                } catch {
                    guard let self, self.generation == token else { return }
                    self.errorMessage = error.localizedDescription
                    self.status = "Scan failed. Previous results, if any, are unchanged."
                    self.isScanning = false
                }
            } onCancel: {
                worker.cancel()
                channel.continuation.finish()
            }
        }
    }

    func rescan() { if let scanURL { scan(scanURL, elevated: resultIsElevated) } }

    /// Recompute the whole snapshot so parent totals, sorting and the treemap agree.
    func refreshSelected() {
        guard selected != nil, !isScanning, !isFileOperation, let scanURL else { return }
        scan(scanURL, elevated: resultIsElevated, preservingView: true)
    }

    func refreshHelperStatus() { helperStatus = ElevatedService.statusDescription }

    func enableHelper() {
        do { try ElevatedService.enable() }
        catch { errorMessage = error.localizedDescription }
        refreshHelperStatus()
    }

    func disableHelper() {
        Task {
            do { try await ElevatedService.disable() }
            catch { errorMessage = error.localizedDescription }
            refreshHelperStatus()
        }
    }

    func scanAsAdministrator() {
        guard let url = lastRequestedURL, ElevatedService.status == .enabled else { return }
        showAccessSettings = false
        scan(url, elevated: true)
    }

    func cancel() {
        generation = UUID()
        scanTask?.cancel()
        scanTask = nil
        if isScanning { status = snapshot == nil ? "Scan cancelled. Choose a folder to try again." : "Scan cancelled. Showing the previous completed scan." }
        isScanning = false
    }

    func zoom(to id: Int) {
        guard let snapshot, snapshot.nodes.indices.contains(id), snapshot.nodes[id].isDirectory else { return }
        currentRoot = id
        selectedID = id
    }

    func goUp() {
        guard let parent = snapshot?.nodes[currentRoot].parent else { return }
        zoom(to: parent)
    }

    func reveal() {
        guard let selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selected.url])
    }

    func trashSelected() {
        guard canTrash, let selected, let snapshot else { return }
        let rootURL = scanURL ?? snapshot.root.url
        let alert = NSAlert()
        alert.messageText = "Move “\(selected.name)” to the Trash?"
        alert.informativeText = selected.isDirectory
            ? "This moves the folder and everything currently inside it to the Trash. You can restore it in Finder."
            : "You can restore this item from the Trash in Finder."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isFileOperation = true
        status = "Moving “\(selected.name)” to the Trash…"
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    let access = rootURL.startAccessingSecurityScopedResource()
                    defer { if access { rootURL.stopAccessingSecurityScopedResource() } }
                    return try FileActions.trash(snapshot: snapshot, nodeID: selected.id)
                }.value
                isFileOperation = false
                scan(rootURL, elevated: resultIsElevated)
            } catch {
                isFileOperation = false
                status = "The Trash operation did not complete. Check the item in Finder."
                errorMessage = "Could not move the item to the Trash: \(error.localizedDescription)"
            }
        }
    }
}
