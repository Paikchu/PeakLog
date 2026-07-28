import CryptoKit
import Foundation
import Security

nonisolated struct AppleSignInNonce: Equatable, Sendable {
    let rawValue: String
    let hashedValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
        hashedValue = SHA256.hash(data: Data(rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func random() throws -> AppleSignInNonce {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppleSignInNonceError.generationFailed
        }

        let rawValue = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return AppleSignInNonce(rawValue: rawValue)
    }
}

nonisolated enum AppleSignInNonceError: Error, Equatable, Sendable {
    case generationFailed
}
