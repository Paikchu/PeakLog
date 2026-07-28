import XCTest
@testable import PeakLog

final class AppleSignInNonceTests: XCTestCase {
    func testHashUsesSHA256Hex() {
        let nonce = AppleSignInNonce(rawValue: "hello")

        XCTAssertEqual(
            nonce.hashedValue,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testRandomNonceUsesUniqueURLSafeValues() throws {
        let first = try AppleSignInNonce.random()
        let second = try AppleSignInNonce.random()

        XCTAssertNotEqual(first.rawValue, second.rawValue)
        XCTAssertFalse(first.rawValue.contains("+"))
        XCTAssertFalse(first.rawValue.contains("/"))
        XCTAssertFalse(first.rawValue.contains("="))
    }
}
