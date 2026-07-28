import AuthenticationServices
import Foundation

nonisolated enum AppleAuthorizationResolution: Equatable, Sendable {
    case credential(AppleSignInCredential)
    case cancelled
    case failed
}

nonisolated enum AppleAuthorizationResolver {
    static func resolve(
        identityToken: Data?,
        nonce: AppleSignInNonce?,
        fullName: String? = nil,
        givenName: String? = nil,
        familyName: String? = nil
    ) -> AppleAuthorizationResolution {
        guard
            let identityToken,
            let idToken = String(data: identityToken, encoding: .utf8),
            !idToken.isEmpty,
            let nonce
        else {
            return .failed
        }

        return .credential(
            AppleSignInCredential(
                idToken: idToken,
                nonce: nonce.rawValue,
                fullName: fullName,
                givenName: givenName,
                familyName: familyName
            )
        )
    }

    static func resolve(
        errorCode: ASAuthorizationError.Code?
    ) -> AppleAuthorizationResolution {
        errorCode == .canceled ? .cancelled : .failed
    }
}
