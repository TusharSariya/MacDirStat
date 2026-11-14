import SwiftUI

struct DiskCommands: Commands {
    @FocusedObject private var model: ScanViewModel?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") { model?.openFolder() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model == nil || model?.isFileOperation == true)
            Button("Rescan") { model?.rescan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model?.scanURL == nil || model?.isScanning == true || model?.isFileOperation == true)
            Button("Cancel Scan") { model?.cancel() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(model?.isScanning != true)
        }
        CommandMenu("Navigate") {
            Button("Enclosing Folder") { model?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model == nil || model?.currentRoot == 0)
            Button("Zoom into Selected Folder") {
                if let id = model?.selectedID { model?.zoom(to: id) }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(model?.selected?.isDirectory != true)
            Divider()
            Button("Reveal in Finder") { model?.reveal() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.selected == nil)
            Button("Move to Trash…") { model?.trashSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model?.canTrash != true)
        }
    }
}
