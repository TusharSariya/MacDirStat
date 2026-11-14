import Foundation
import Darwin

struct FileIdentity: Sendable, Equatable, Codable {
    let device: Int32
    let inode: UInt64
    let kind: UInt16

    static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Self(device: info.st_dev, inode: info.st_ino, kind: info.st_mode & S_IFMT)
    }
}
