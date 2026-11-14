import Foundation
import ServiceManagement

@MainActor
enum ElevatedService {
    static var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MacDirStatElevatedBuild") as? Bool == true &&
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/MacDirStatScanner").path) &&
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/" + ElevatedConfiguration.plistName).path)
    }

    static var status: SMAppService.Status {
        SMAppService.daemon(plistName: ElevatedConfiguration.plistName).status
    }

    static var statusDescription: String {
        guard isAvailable else { return "Available in the signed direct-distribution build." }
        switch status {
        case .notRegistered: return "Administrator scanner is not enabled."
        case .enabled: return "Administrator scanner is enabled. Each scan requires OS authorization."
        case .requiresApproval: return "Approve MacDirStat in System Settings → General → Login Items & Extensions."
        case .notFound: return "macOS could not find a registered scanner. Enable it to register the bundled helper."
        @unknown default: return "Unknown administrator scanner status."
        }
    }

    static func enable() throws {
        guard isAvailable else { throw ElevatedError.message(statusDescription) }
        _ = try PeerSigning.ownTeamIdentifier()
        try SMAppService.daemon(plistName: ElevatedConfiguration.plistName).register()
    }

    static func disable() async throws {
        try await SMAppService.daemon(plistName: ElevatedConfiguration.plistName).unregister()
    }

    static func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
}
