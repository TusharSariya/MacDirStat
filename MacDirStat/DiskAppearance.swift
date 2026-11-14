import SwiftUI

extension DiskFileType {
    var color: Color {
        switch self {
        case .video: return .blue
        case .audio: return .purple
        case .image: return .green
        case .document: return .orange
        case .code: return .cyan
        case .archive: return .yellow
        case .other: return .gray
        }
    }
    var icon: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .document: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archive: return "archivebox"
        case .other: return "doc"
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
