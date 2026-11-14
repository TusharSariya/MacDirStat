import ServiceManagement
import SwiftUI

struct ContentView: View {
    @StateObject private var model = ScanViewModel()

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot = model.snapshot {
                HStack(spacing: 8) {
                    Button(action: model.goUp) { Image(systemName: "arrow.up") }
                        .disabled(model.currentRoot == 0)
                        .help("Enclosing folder")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(snapshot.ancestors(of: model.currentRoot), id: \.self) { id in
                                Button(snapshot.nodes[id].name) { model.zoom(to: id) }.buttonStyle(.link)
                                if id != model.currentRoot { Image(systemName: "chevron.right").font(.caption2) }
                            }
                        }
                    }
                    if model.resultIsElevated {
                        Label("Administrator scan", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(formatBytes(snapshot.nodes[model.currentRoot].bytes(model.metric)))
                        .monospacedDigit().fontWeight(.semibold)
                }
                .padding(10)
                Divider()
                HSplitView {
                    FileTreeView(model: model).frame(minWidth: 240, idealWidth: 320, maxWidth: 480)
                    VStack(spacing: 0) {
                        TreemapView(model: model)
                        Divider()
                        Text("Click to select · Double-click to zoom · Tiny items are grouped")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                    }.frame(minWidth: 350, idealWidth: 650)
                    FileDetailView(model: model).frame(minWidth: 230, idealWidth: 250, maxWidth: 350)
                }
            } else {
                ContentUnavailableView {
                    Label("See what’s taking up space", systemImage: "internaldrive")
                } description: {
                    Text("Choose a folder or volume to explore its files. Scanning reads metadata, not file contents.")
                } actions: {
                    Button("Choose Folder…", action: model.openFolder).buttonStyle(.borderedProminent)
                }
            }
            Divider()
            HStack(spacing: 10) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scanning \(model.progress.count.formatted()) items · \(formatBytes(model.progress.bytes))")
                        Text(model.progress.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", action: model.cancel)
                } else {
                    Text(model.status).foregroundStyle(.secondary)
                    Spacer()
                    if let snapshot = model.snapshot, snapshot.issueCount > 0 {
                        Button("\(snapshot.issueCount) scan issues", systemImage: "exclamationmark.triangle") { model.showIssues = true }
                    }
                }
            }
            .font(.caption).padding(10).frame(height: 58)
        }
        .frame(minWidth: 950, minHeight: 550)
        .navigationTitle(model.snapshot?.root.name ?? "MacDirStat")
        .toolbar {
            ToolbarItemGroup {
                Button(action: model.openFolder) { Label("Open Folder", systemImage: "folder.badge.plus") }
                    .disabled(model.isFileOperation)
                Button(action: model.rescan) { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.scanURL == nil || model.isScanning || model.isFileOperation)
                Button { model.refreshHelperStatus(); model.showAccessSettings = true } label: {
                    Label("Scan Access", systemImage: "lock.shield")
                }
                Picker("Size measure", selection: $model.metric) {
                    ForEach(SizeMetric.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 145)
                Picker("Sort", selection: $model.sort) {
                    ForEach(DiskSort.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 110)
            }
        }
        .alert("MacDirStat", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $model.showIssues) { ScanIssuesView(model: model) }
        .sheet(isPresented: $model.showAccessSettings) { ScanAccessView(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshHelperStatus() }
        .focusedSceneObject(model)
        .onDisappear { model.cancel() }
    }
}

struct FileDetailView: View {
    @ObservedObject var model: ScanViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let node = model.selected {
                    Image(systemName: node.isDirectory ? "folder.fill" : node.isSymbolicLink ? "link" : node.fileType.icon)
                        .font(.system(size: 36)).foregroundStyle(node.isDirectory ? .yellow : node.fileType.color)
                    Text(node.name).font(.headline).textSelection(.enabled).id("name-\(node.id)")
                    Text(node.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).id("path-\(node.id)")
                    Divider()
                    LabeledContent("File size", value: formatBytes(node.logicalSize))
                    LabeledContent("Size on disk", value: formatBytes(node.allocatedSize))
                    if node.isDirectory { LabeledContent("Items", value: node.descendantCount.formatted()) }
                    if let date = node.modified { LabeledContent("Modified", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    if node.isSymbolicLink { Text("Symbolic link · target not scanned").foregroundStyle(.secondary) }
                    if node.hasScanError { Text("Some contents could not be read. Totals may be incomplete.").foregroundStyle(.orange) }
                    Button("Reveal in Finder", systemImage: "magnifyingglass", action: model.reveal)
                    if node.isDirectory { Button("Zoom into Folder", systemImage: "arrow.down.right.and.arrow.up.left") { model.zoom(to: node.id) } }
                    Button("Move to Trash…", systemImage: "trash", role: .destructive, action: model.trashSelected)
                        .disabled(!model.canTrash)
                    Divider()
                } else { Text("Select a file or folder").foregroundStyle(.secondary) }
                Text("File Types · Entire Scan").font(.headline)
                if model.snapshot != nil {
                    ForEach(model.summary) { summary in
                        HStack {
                            Circle().fill(summary.type.color).frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text(summary.type.displayName)
                                Text("\(summary.count.formatted()) \(summary.count == 1 ? "file" : "files")").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(formatBytes(summary.bytes)).monospacedDigit()
                        }
                    }
                }
                Text("Size on disk is reported allocation, not guaranteed reclaimable space. APFS clones, hard links, compression and snapshots can affect totals.")
                    .foregroundStyle(.secondary)
            }.font(.caption).padding(16)
        }
    }
}

struct ScanIssuesView: View {
    @ObservedObject var model: ScanViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan Issues").font(.title2.bold())
            Text("Unreadable locations are skipped. macOS privacy controls may require Full Disk Access in System Settings, even for an administrator. Grant access only to locations you want to scan, then rescan.")
            if let snapshot = model.snapshot {
                Text("\(snapshot.issueCount) issues; showing the first \(snapshot.issues.count).")
                List(snapshot.issues) { issue in
                    VStack(alignment: .leading) {
                        Text(issue.path).textSelection(.enabled)
                        Text(issue.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Open System Settings") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 650, height: 450)
    }
}


struct ScanAccessView: View {
    @ObservedObject var model: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Scan Access", systemImage: "lock.shield").font(.title2.bold())
            Text("Ordinary scans use your account’s access. For folders restricted by file ownership, you can enable a read-only administrator scanner. macOS asks you to authorize it. File moves and Trash always use your ordinary account.")
            Text(model.helperStatus).foregroundStyle(.secondary)
            HStack {
                Button("Enable Administrator Scanner…", action: model.enableHelper)
                    .disabled(!ElevatedService.isAvailable || (ElevatedService.status != .notRegistered && ElevatedService.status != .notFound) || model.isScanning)
                Button("Approval Settings…", action: ElevatedService.openApprovalSettings)
                    .disabled(!ElevatedService.isAvailable)
                Button("Disable Scanner", action: model.disableHelper)
                    .disabled(!ElevatedService.isAvailable || (ElevatedService.status != .enabled && ElevatedService.status != .requiresApproval) || model.isScanning)
            }
            if let url = model.lastRequestedURL {
                Button("Scan “\(url.lastPathComponent)” as Administrator…", action: model.scanAsAdministrator)
                    .disabled(!ElevatedService.isAvailable || ElevatedService.status != .enabled || model.isScanning || model.isFileOperation)
            }
            Divider()
            Text("Privacy-protected folders may also need Full Disk Access. Administrator authorization does not bypass macOS privacy protections. Enable Full Disk Access for this app in System Settings only if you need those locations, then try scanning again.")
                .font(.callout)
            HStack {
                Button("Open System Settings") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 660)
    }
}
