import Foundation
import Security

/// An external form is a capability. Keep it in memory and transfer it only over authenticated XPC.
final class ScanAuthorization: @unchecked Sendable {
    private let reference: AuthorizationRef
    let externalForm: Data

    private init(reference: AuthorizationRef, externalForm: Data) {
        self.reference = reference
        self.externalForm = externalForm
    }

    deinit { AuthorizationFree(reference, [.destroyRights]) }

    static func request() throws -> ScanAuthorization {
        var reference: AuthorizationRef?
        try check(AuthorizationCreate(nil, nil, [], &reference))
        guard let reference else { throw ElevatedError.message("Could not create an authorization request.") }
        do {
            try rights(reference, flags: [.interactionAllowed, .extendRights, .preAuthorize])
            var external = AuthorizationExternalForm()
            try check(AuthorizationMakeExternalForm(reference, &external))
            let data = withUnsafeBytes(of: &external) { Data($0) }
            return ScanAuthorization(reference: reference, externalForm: data)
        } catch {
            AuthorizationFree(reference, [.destroyRights])
            throw error
        }
    }

    static func verify(_ data: Data) throws {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else {
            throw ElevatedError.message("Invalid scan authorization.")
        }
        var external = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &external) { data.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        try check(AuthorizationCreateFromExternalForm(&external, &reference))
        guard let reference else { throw ElevatedError.message("Missing scan authorization.") }
        defer { AuthorizationFree(reference, []) }
        // The helper never prompts. The app must have obtained the right from the OS first.
        try rights(reference, flags: [.extendRights])
    }

    private static func rights(_ reference: AuthorizationRef, flags: AuthorizationFlags) throws {
        try kAuthorizationRightExecute.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            try withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                try check(AuthorizationCopyRights(reference, &rights, nil, flags, nil))
            }
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errAuthorizationSuccess else {
            if status == errAuthorizationCanceled { throw CancellationError() }
            throw ElevatedError.message("Administrator authorization was not granted (\(status)).")
        }
    }
}
