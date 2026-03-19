import Foundation

// MARK: - API Error
enum APIError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case notFound
    case serverError(Int)
    case decodingFailed(Error)
    case networkError(Error)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "error.api.invalid_url")
        case .unauthorized:
            return String(localized: "error.api.unauthorized")
        case .notFound:
            return String(localized: "error.api.not_found")
        case .serverError(let code):
            return String(
                format: String(localized: "error.api.server_format"),
                locale: Locale(identifier: AppLanguage.current().localeIdentifier),
                code
            )
        case .decodingFailed(let error):
            return String(
                format: String(localized: "error.api.decoding_format"),
                locale: Locale(identifier: AppLanguage.current().localeIdentifier),
                error.localizedDescription
            )
        case .networkError(let error):
            return String(
                format: String(localized: "error.api.network_format"),
                locale: Locale(identifier: AppLanguage.current().localeIdentifier),
                error.localizedDescription
            )
        case .unknown:
            return String(localized: "error.api.unknown")
        }
    }
}

// MARK: - API Client
/// Base HTTP client. Replace `baseURL` and `authToken` to connect to a real backend.
final class APIClient {
    static let shared = APIClient()

    // TODO: Set this to your backend base URL before release
    var baseURL: URL = URL(string: "https://api.peaklog.app/v1")!

    // TODO: Populate from your auth flow (e.g. JWT from sign-in response)
    var authToken: String? = nil

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Request Builder
    func request(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil,
        body: Encodable? = nil
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems

        guard let url = components.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = authToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            req.httpBody = try encoder.encode(body)
        }

        return req
    }

    // MARK: - Execute
    func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown
        }

        switch httpResponse.statusCode {
        case 200...299: break
        case 401: throw APIError.unauthorized
        case 404: throw APIError.notFound
        default: throw APIError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }
}
