import Foundation
import Supabase
@testable import PeakLog

final class StubTokenProvider: TokenProviding, @unchecked Sendable {
    enum Behavior {
        case token(String)
        case failure
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var _calls = 0

    init(_ behavior: Behavior = .token("preflight-token")) {
        self.behavior = behavior
    }

    var calls: Int {
        lock.withLock { _calls }
    }

    func validToken() async throws -> String {
        lock.withLock { _calls += 1 }
        switch behavior {
        case .token(let token):
            return token
        case .failure:
            throw AppAuthError.invalidCredentials
        }
    }
}

enum SupabaseSDKTestClient {
    static func make() -> SupabaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SDKRecordingURLProtocol.self]
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        return SupabaseClientFactory(
            config: SupabaseConfig(
                url: URL(string: "https://example.supabase.co")!,
                publishableKey: "sb_publishable_test"
            ),
            authSession: session,
            apiSession: session
        ).makeAPIClient {
            "sdk-token"
        }
    }
}

final class SDKRecordingURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let status: Int?
        let body: Data
        let error: Error?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func enqueue(status: Int, body: Data = Data()) {
        lock.withLock {
            stubs.append(Stub(status: status, body: body, error: nil))
        }
    }

    static func enqueueJSON(_ json: String, status: Int = 200) {
        enqueue(status: status, body: Data(json.utf8))
    }

    static func enqueue(error: Error) {
        lock.withLock {
            stubs.append(Stub(status: nil, body: Data(), error: error))
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
        let stub = Self.lock.withLock {
            Self.recordedRequests.append(request)
            return Self.stubs.isEmpty
                ? Stub(status: 500, body: Data(), error: nil)
                : Self.stubs.removeFirst()
        }

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

    override func stopLoading() {}
}
