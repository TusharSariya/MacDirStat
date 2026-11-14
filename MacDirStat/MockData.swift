//
//  MockData.swift
//  MacDirStat
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - File Node

class FileNode: Identifiable, ObservableObject, Hashable {
    let id = UUID()

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    let name: String
    let size: Int64  // bytes
    let isDirectory: Bool
    let fileType: FileType
    var children: [FileNode]

    var childrenOrNil: [FileNode]? {
        isDirectory && !children.isEmpty ? children : nil
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    init(name: String, size: Int64, isDirectory: Bool, fileType: FileType = .other, children: [FileNode] = []) {
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.fileType = fileType
        self.children = children
    }
}

// MARK: - File Type

enum FileType: String, CaseIterable {
    case video, audio, image, document, code, archive, other

    var color: Color {
        switch self {
        case .video:    return .blue
        case .audio:    return .purple
        case .image:    return .green
        case .document: return .orange
        case .code:     return .cyan
        case .archive:  return .yellow
        case .other:    return .gray
        }
    }

    var icon: String {
        switch self {
        case .video:    return "film"
        case .audio:    return "music.note"
        case .image:    return "photo"
        case .document: return "doc.text"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .archive:  return "archivebox"
        case .other:    return "doc"
        }
    }
}

// MARK: - Mock Tree

extension FileNode {
    static var mockRoot: FileNode {
        FileNode(name: "Home", size: 0, isDirectory: true, children: [
            FileNode(name: "Movies", size: 0, isDirectory: true, children: [
                FileNode(name: "Vacation 2024.mov", size: 4_200_000_000, isDirectory: false, fileType: .video),
                FileNode(name: "Birthday.mp4",      size: 1_800_000_000, isDirectory: false, fileType: .video),
                FileNode(name: "Old Backup.mkv",    size: 8_500_000_000, isDirectory: false, fileType: .video),
            ]),
            FileNode(name: "Music", size: 0, isDirectory: true, children: [
                FileNode(name: "Library.itl",       size: 900_000_000,  isDirectory: false, fileType: .audio),
                FileNode(name: "Podcasts",          size: 0, isDirectory: true, children: [
                    FileNode(name: "Episode 1.mp3", size: 120_000_000,  isDirectory: false, fileType: .audio),
                    FileNode(name: "Episode 2.mp3", size: 95_000_000,   isDirectory: false, fileType: .audio),
                ]),
            ]),
            FileNode(name: "Pictures", size: 0, isDirectory: true, children: [
                FileNode(name: "Screenshots",       size: 0, isDirectory: true, children: [
                    FileNode(name: "shot1.png",     size: 2_500_000,    isDirectory: false, fileType: .image),
                    FileNode(name: "shot2.png",     size: 1_800_000,    isDirectory: false, fileType: .image),
                    FileNode(name: "shot3.png",     size: 3_100_000,    isDirectory: false, fileType: .image),
                ]),
                FileNode(name: "RAW",               size: 0, isDirectory: true, children: [
                    FileNode(name: "IMG_001.cr2",   size: 24_000_000,   isDirectory: false, fileType: .image),
                    FileNode(name: "IMG_002.cr2",   size: 26_000_000,   isDirectory: false, fileType: .image),
                    FileNode(name: "IMG_003.cr2",   size: 22_000_000,   isDirectory: false, fileType: .image),
                ]),
            ]),
            FileNode(name: "Documents", size: 0, isDirectory: true, children: [
                FileNode(name: "Resume.pdf",        size: 450_000,      isDirectory: false, fileType: .document),
                FileNode(name: "Taxes 2024.pdf",    size: 2_100_000,    isDirectory: false, fileType: .document),
                FileNode(name: "Notes.md",          size: 12_000,       isDirectory: false, fileType: .document),
            ]),
            FileNode(name: "Developer", size: 0, isDirectory: true, children: [
                FileNode(name: "Projects",          size: 0, isDirectory: true, children: [
                    FileNode(name: "MacDirStat",    size: 0, isDirectory: true, children: [
                        FileNode(name: "MacDirStat.xcodeproj", size: 80_000, isDirectory: false, fileType: .code),
                        FileNode(name: "ContentView.swift",    size: 12_000, isDirectory: false, fileType: .code),
                    ]),
                ]),
                FileNode(name: "DerivedData",       size: 0, isDirectory: true, children: [
                    FileNode(name: "MacDirStat-abc", size: 650_000_000, isDirectory: false, fileType: .archive),
                ]),
            ]),
            FileNode(name: "Downloads", size: 0, isDirectory: true, children: [
                FileNode(name: "Xcode_15.xip",      size: 7_200_000_000, isDirectory: false, fileType: .archive),
                FileNode(name: "installer.dmg",     size: 300_000_000,   isDirectory: false, fileType: .archive),
                FileNode(name: "notes.txt",         size: 8_000,         isDirectory: false, fileType: .document),
            ]),
        ])
    }
}

// Compute recursive sizes after building the tree
extension FileNode {
    @discardableResult
    func computeSizes() -> Int64 {
        if isDirectory {
            let total = children.reduce(0) { $0 + $1.computeSizes() }
            // We use a mirror trick — just return; actual size is computed on demand
            return total
        }
        return size
    }

    var totalSize: Int64 {
        if isDirectory {
            return children.reduce(0) { $0 + $1.totalSize }
        }
        return size
    }
}
