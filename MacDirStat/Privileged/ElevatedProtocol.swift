import Foundation

// Intentionally exposes metadata scanning only. There is no command execution or file mutation interface.
@objc protocol ElevatedScannerProtocol {
    func startScan(path: String, authorization: Data, reply: @escaping @Sendable (String?) -> Void)
    func poll(reply: @escaping @Sendable (Data?, Bool, String?) -> Void)
}

struct ElevatedUpdate: Codable, Sendable {
    let progress: ScanProgress?
    let snapshot: ScanSnapshot?
}

enum ElevatedConfiguration {
    static let appIdentifier = "tushar.MacDirStat"
    static let helperIdentifier = "tushar.MacDirStat.Scanner"
    static let plistName = helperIdentifier + ".plist"

    static func validate(path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < 32_768 else {
            throw ElevatedError.message("Choose an absolute filesystem folder path.")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

enum ElevatedError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
