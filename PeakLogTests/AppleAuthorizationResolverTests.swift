import AuthenticationServices
import XCTest
@testable import PeakLog

final class AppleAuthorizationResolverTests: XCTestCase {
    func testValidTokenAndNonceProduceCredential() {
        let nonce = AppleSignInNonce(rawValue: "raw-nonce")

        let resolution = AppleAuthorizationResolver.resolve(
            identityToken: Data("id-token".utf8),
            nonce: nonce,
            fullName: "Max Peak",
            givenName: "Max",
            familyName: "Peak"
        )

        XCTAssertEqual(
            resolution,
            .credential(
                AppleSignInCredential(
                    idToken: "id-token",
                    nonce: "raw-nonce",
                    fullName: "Max Peak",
                    givenName: "Max",
                    familyName: "Peak"
                )
            )
        )
    }

    func testMissingOrInvalidTokenFailsAuthorization() {
        let nonce = AppleSignInNonce(rawValue: "raw-nonce")

        XCTAssertEqual(
            AppleAuthorizationResolver.resolve(identityToken: nil, nonce: nonce),
            .failed
        )
        XCTAssertEqual(
            AppleAuthorizationResolver.resolve(identityToken: Data([0xFF]), nonce: nonce),
            .failed
        )
        XCTAssertEqual(
            AppleAuthorizationResolver.resolve(identityToken: Data(), nonce: nonce),
            .failed
        )
        XCTAssertEqual(
            AppleAuthorizationResolver.resolve(
                identityToken: Data("id-token".utf8),
                nonce: nil
            ),
            .failed
        )
    }

    func testAuthorizationCancellationIsSilent() {
        XCTAssertEqual(
            AppleAuthorizationResolver.resolve(errorCode: .canceled),
            .cancelled
        )
        XCTAssertEqual(
            AppleAuthorizationResolver.resolve(errorCode: .failed),
            .failed
        )
        XCTAssertEqual(
            AppleAuthorizationResolver.resolve(errorCode: nil),
            .failed
        )
    }
}
