import Foundation
import Security

/// Both peers require the same Apple signing team and the expected executable identifier.
/// Ad-hoc signatures deliberately cannot enable administrator scanning.
enum PeerSigning {
    static func ownTeamIdentifier() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw ElevatedError.message("Cannot inspect this executable’s signature.")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw ElevatedError.message("Cannot inspect the static code signature.")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ElevatedError.message("Administrator scanning requires an Apple-signed build with a signing team. Use the signed direct-distribution build.")
        }
        return team
    }

    static func requirement(identifier: String) throws -> String {
        let team = try ownTeamIdentifier()
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
