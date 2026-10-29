import Foundation
import Security

/// Ladle's own code signature.
enum CodeSignature {
    /// The Apple developer team in Ladle's signature, or nil for an ad-hoc signed build (the free
    /// release builds, and local builds), which has none.
    static let teamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }()
}

/// What Settings › Browsers says about Safari. Safari only loads extensions from apps signed by a
/// registered Apple developer, so a build without a team can't run Ladle's Safari extension.
enum SafariExtensionStatus: Equatable {
    case needsSignedBuild
    case on
    case off
    /// Safari hasn't said yet.
    case unknown

    init(teamIdentifier: String?, enabled: Bool?) {
        guard let teamIdentifier, !teamIdentifier.isEmpty else {
            self = .needsSignedBuild
            return
        }
        switch enabled {
        case true?: self = .on
        case false?: self = .off
        case nil: self = .unknown
        }
    }

    var text: String {
        switch self {
        case .needsSignedBuild: return "The Safari extension needs a signed build of Ladle"
        case .on: return "Extension on"
        case .off: return "Turned off in Safari"
        case .unknown: return "Comes with Ladle"
        }
    }
}
