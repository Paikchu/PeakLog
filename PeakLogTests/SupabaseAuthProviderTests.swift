import Supabase
import XCTest
@testable import PeakLog

final class SupabaseAuthProviderTests: XCTestCase {
    override func tearDown() {
        RecordingURLProtocol.reset()
        super.tearDown()
    }

    func testSignInMapsUser() async throws {
        RecordingURLProtocol.enqueue(status: 200, body: authResponse())
        let provider = makeProvider()

        let user = try await provider.signIn(email: "user@example.com", password: "password")

        XCTAssertEqual(user.id, Self.userID.uuidString.lowercased())
        XCTAssertEqual(user.email, "user@example.com")
    }

    func testAuthAndAPISessionTimeoutsAreExplicit() {
        let auth = SupabaseClientFactory.sessionConfiguration(timeout: 30)
        let api = SupabaseClientFactory.sessionConfiguration(timeout: 60)

        XCTAssertEqual(auth.timeoutIntervalForRequest, 30)
        XCTAssertEqual(auth.timeoutIntervalForResource, 30)
        XCTAssertEqual(api.timeoutIntervalForRequest, 60)
        XCTAssertEqual(api.timeoutIntervalForResource, 60)
    }

    func testRestoreKeepsExpiredLocalSessionOnNetworkFailure() async throws {
        RecordingURLProtocol.enqueue(error: URLError(.notConnectedToInternet))
        let storage = TestAuthStorage()
        try seed(expiredSession(), into: storage)
        let provider = makeProvider(storage: storage)

        let user = await provider.restoreUser()

        XCTAssertEqual(user?.id, Self.userID.uuidString.lowercased())
        XCTAssertNotNil(try storage.retrieve(key: SupabaseClientFactory.authStorageKey))
    }

    func testRejectedRefreshClearsSDKSession() async throws {
        RecordingURLProtocol.enqueue(status: 401, body: #"{"message":"Invalid Refresh Token"}"#.data(using: .utf8)!)
        RecordingURLProtocol.enqueue(status: 204, body: Data())
        let storage = TestAuthStorage()
        try seed(expiredSession(), into: storage)
        let provider = makeProvider(storage: storage)

        do {
            _ = try await provider.validToken()
            XCTFail("Expected rejected refresh")
        } catch AppAuthError.invalidCredentials {
        }

        XCTAssertNil(try storage.retrieve(key: SupabaseClientFactory.authStorageKey))
    }

    func testSignOutUsesLocalScopeAndClearsStorage() async throws {
        RecordingURLProtocol.enqueue(status: 204, body: Data())
        let storage = TestAuthStorage()
        try seed(validSession(), into: storage)
        let provider = makeProvider(storage: storage)

        await provider.signOut()

        let request = try XCTUnwrap(RecordingURLProtocol.requests.last)
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "scope" })?.value, "local")
        XCTAssertNil(try storage.retrieve(key: SupabaseClientFactory.authStorageKey))
    }

    func testSignOutClearsStorageWhenLogoutRequestFails() async throws {
        RecordingURLProtocol.enqueue(error: URLError(.notConnectedToInternet))
        let storage = TestAuthStorage()
        try seed(validSession(), into: storage)
        let provider = makeProvider(storage: storage)
        storage.resetRemoveCallCount()

        await provider.signOut()

        XCTAssertNil(try storage.retrieve(key: SupabaseClientFactory.authStorageKey))
        XCTAssertGreaterThanOrEqual(storage.removeCallCount, 2)
    }

    func testConcurrentValidTokenCallsShareOneSDKRefresh() async throws {
        RecordingURLProtocol.enqueue(status: 200, body: authResponse(), delay: 0.1)
        let storage = TestAuthStorage()
        try seed(expiredSession(), into: storage)
        let provider = makeProvider(storage: storage)

        async let first = provider.validToken()
        async let second = provider.validToken()
        let tokens = try await [first, second]

        XCTAssertEqual(tokens, ["fresh-access-token", "fresh-access-token"])
        XCTAssertEqual(RecordingURLProtocol.requests.filter(isRefreshRequest).count, 1)
    }

    func testInvalidStoredPayloadIsRemoved() throws {
        let storage = TestAuthStorage()
        try storage.store(key: SupabaseClientFactory.authStorageKey, value: Data("legacy-session".utf8))
        let validating = ValidatingAuthLocalStorage(storage: storage)

        XCTAssertNil(try validating.retrieve(key: SupabaseClientFactory.authStorageKey))
        XCTAssertNil(try storage.retrieve(key: SupabaseClientFactory.authStorageKey))
    }

    func testSDKSessionPayloadIsRetained() throws {
        let storage = TestAuthStorage()
        let payload = try JSONEncoder().encode(validSession())
        try storage.store(key: SupabaseClientFactory.authStorageKey, value: payload)
        let validating = ValidatingAuthLocalStorage(storage: storage)

        XCTAssertEqual(try validating.retrieve(key: SupabaseClientFactory.authStorageKey), payload)
    }

    func testNonSessionAuthPayloadIsRetained() throws {
        let storage = TestAuthStorage()
        let key = "\(SupabaseClientFactory.authStorageKey)-code-verifier"
        let payload = Data("pkce-code-verifier".utf8)
        try storage.store(key: key, value: payload)
        let validating = ValidatingAuthLocalStorage(storage: storage)

        XCTAssertEqual(try validating.retrieve(key: key), payload)
    }

    private func makeProvider(storage: TestAuthStorage = TestAuthStorage()) -> SupabaseAuthProvider {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RecordingURLProtocol.self]
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: sessionConfiguration)
        let factory = SupabaseClientFactory(
            config: SupabaseConfig(
                url: URL(string: "https://example.supabase.co")!,
                publishableKey: "sb_publishable_test"
            ),
            authStorage: ValidatingAuthLocalStorage(storage: storage),
            authSession: session,
            apiSession: session
        )
        return SupabaseAuthProvider(
            client: factory.makeAuthClient(),
            clearPersistedSession: {
                try storage.remove(key: SupabaseClientFactory.authStorageKey)
            }
        )
    }

    private func seed(_ session: Session, into storage: TestAuthStorage) throws {
        try storage.store(
            key: SupabaseClientFactory.authStorageKey,
            value: JSONEncoder().encode(session)
        )
    }

    private func validSession() -> Session {
        session(expiresAt: Date().addingTimeInterval(3_600).timeIntervalSince1970)
    }

    private func expiredSession() -> Session {
        session(expiresAt: Date().addingTimeInterval(-3_600).timeIntervalSince1970)
    }

    private func session(expiresAt: TimeInterval) -> Session {
        Session(
            accessToken: "expired-access-token",
            tokenType: "bearer",
            expiresIn: 3_600,
            expiresAt: expiresAt,
            refreshToken: "refresh-token",
            user: User(
                id: Self.userID,
                appMetadata: [:],
                userMetadata: [:],
                aud: "authenticated",
                email: "user@example.com",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

    private func authResponse() -> Data {
        let expiresAt = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        return """
        {
          "access_token": "fresh-access-token",
          "token_type": "bearer",
          "expires_in": 3600,
          "expires_at": \(expiresAt),
          "refresh_token": "fresh-refresh-token",
          "user": {
            "id": "\(Self.userID.uuidString.lowercased())",
            "aud": "authenticated",
            "email": "user@example.com",
            "created_at": "2023-11-14T22:13:20Z",
            "updated_at": "2023-11-14T22:13:20Z",
            "app_metadata": {},
            "user_metadata": {}
          }
        }
        """.data(using: .utf8)!
    }

    private func isRefreshRequest(_ request: URLRequest) -> Bool {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: {
                $0.name == "grant_type" && $0.value == "refresh_token"
            }) == true
    }

    private static let userID = UUID(uuidString: "859F402D-B3DE-4105-A1B9-932836D9193B")!
}

private final class TestAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var _removeCallCount = 0

    var removeCallCount: Int {
        lock.withLock { _removeCallCount }
    }

    func resetRemoveCallCount() {
        lock.withLock { _removeCallCount = 0 }
    }

    func store(key: String, value: Data) throws {
        lock.withLock { values[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    func remove(key: String) throws {
        lock.withLock {
            _removeCallCount += 1
            values[key] = nil
        }
    }
}

private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Stub {
        let status: Int?
        let body: Data
        let error: Error?
        let delay: TimeInterval
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func enqueue(status: Int, body: Data, delay: TimeInterval = 0) {
        lock.withLock {
            stubs.append(Stub(status: status, body: body, error: nil, delay: delay))
        }
    }

    static func enqueue(error: Error, delay: TimeInterval = 0) {
        lock.withLock {
            stubs.append(Stub(status: nil, body: Data(), error: error, delay: delay))
        }
    }

    static func reset() {
        lock.withLock {
            stubs = []
            recordedRequests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: Stub = Self.lock.withLock {
            Self.recordedRequests.append(request)
            return Self.stubs.isEmpty
                ? Stub(status: 500, body: Data(), error: nil, delay: 0)
                : Self.stubs.removeFirst()
        }

        let respond = { [request, weak self] in
            guard let self else { return }
            if let error = stub.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status!,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}
}
