import SwiftUI

extension DiskFileType {
    var displayName: String { self == .diskImage ? "Disk images" : rawValue.capitalized }
    var color: Color {
        switch self {
        case .video: return Color(red: 0.57, green: 0.43, blue: 0.88)
        case .audio: return Color(red: 0.84, green: 0.39, blue: 0.62)
        case .image: return Color(red: 0.25, green: 0.67, blue: 0.53)
        case .document: return Color(red: 0.83, green: 0.64, blue: 0.28)
        case .code: return Color(red: 0.24, green: 0.62, blue: 0.76)
        case .archive: return Color(red: 0.88, green: 0.48, blue: 0.32)
        case .diskImage: return Color(red: 0.39, green: 0.49, blue: 0.88)
        case .other: return Color(red: 0.43, green: 0.53, blue: 0.62)
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
        case .diskImage: return "externaldrive"
        case .other: return "doc"
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
