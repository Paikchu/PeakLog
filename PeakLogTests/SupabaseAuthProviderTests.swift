import XCTest
@testable import PeakLog

/// Issue #15: every `URLRequest` this provider builds must set an explicit
/// `timeoutInterval` — `URLRequest`'s 60s default leaves auth calls hanging
/// far too long on a bad connection. Intercepts outgoing requests via a
/// custom `URLProtocol` so we can inspect what was actually sent, without
/// touching the network.
final class SupabaseAuthProviderTests: XCTestCase {
    override func tearDown() {
        RecordingURLProtocol.reset()
        super.tearDown()
    }

    func testSignInRequestHasAnExplicitTimeout() async throws {
        let provider = makeProvider(statusCode: 200, body: Self.validTokenResponseJSON)
        _ = try? await provider.signIn(email: "user@example.com", password: "password")

        let request = try XCTUnwrap(RecordingURLProtocol.lastRequest)
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    func testRefreshRequestHasAnExplicitTimeout() async throws {
        let provider = makeProvider(statusCode: 200, body: Self.validTokenResponseJSON)
        _ = try? await provider.refresh(refreshToken: "refresh-token")

        let request = try XCTUnwrap(RecordingURLProtocol.lastRequest)
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    func testSignOutRequestHasAnExplicitTimeout() async throws {
        let provider = makeProvider(statusCode: 204, body: Data())
        await provider.signOut(accessToken: "access-token")

        let request = try XCTUnwrap(RecordingURLProtocol.lastRequest)
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    // MARK: - Helpers

    private func makeProvider(statusCode: Int, body: Data) -> SupabaseAuthProvider {
        RecordingURLProtocol.stubStatusCode = statusCode
        RecordingURLProtocol.stubBody = body

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return SupabaseAuthProvider(
            config: SupabaseConfig(url: URL(string: "https://example.supabase.co")!, anonKey: "anon-key"),
            session: session
        )
    }

    private static let validTokenResponseJSON: Data = """
    {
        "access_token": "access",
        "refresh_token": "refresh",
        "expires_in": 3600,
        "user": { "id": "user-1", "email": "user@example.com" }
    }
    """.data(using: .utf8)!
}

/// Captures the last `URLRequest` it's asked to load and responds with a
/// canned status/body instead of touching the network.
private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _lastRequest: URLRequest?
    nonisolated(unsafe) static var stubStatusCode = 200
    nonisolated(unsafe) static var stubBody = Data()

    static var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequest
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _lastRequest = nil
        stubStatusCode = 200
        stubBody = Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        RecordingURLProtocol.lock.lock()
        RecordingURLProtocol._lastRequest = request
        let statusCode = RecordingURLProtocol.stubStatusCode
        let body = RecordingURLProtocol.stubBody
        RecordingURLProtocol.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
