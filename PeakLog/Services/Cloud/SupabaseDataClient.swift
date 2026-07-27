import Foundation
import Supabase

nonisolated enum CloudError: Error, Equatable, Sendable {
    case notConfigured
    case network
    case unauthorized
    case remote(code: String, message: String)
}

nonisolated struct SupabaseDataClient: Sendable {
    private let client: SupabaseClient
    private let tokenProvider: TokenProviding
    private let retryEnabled: Bool

    init(
        client: SupabaseClient,
        tokenProvider: TokenProviding,
        retryEnabled: Bool = true
    ) {
        self.client = client
        self.tokenProvider = tokenProvider
        self.retryEnabled = retryEnabled
    }

    func fetch<Row: Decodable>(
        _ type: Row.Type,
        table: String,
        query: [URLQueryItem]
    ) async throws -> [Row] {
        try await authorize()
        let columns = query.first(where: { $0.name == "select" })?.value ?? "*"
        let builder = client.from(table).select(columns)
        Self.apply(query, to: builder)
        builder.retry(enabled: retryEnabled)

        do {
            let response: PostgrestResponse<[Row]> = try await builder.execute()
            return response.value
        } catch {
            throw CloudErrorMapper.database(error)
        }
    }

    func upsert<Row: Encodable>(table: String, rows: [Row]) async throws {
        guard !rows.isEmpty else { return }
        try await authorize()
        do {
            let builder = try client
                .from(table)
                .upsert(try Self.normalizedBulkRows(rows), returning: .minimal)
            builder.retry(enabled: retryEnabled)
            try await builder.execute()
        } catch {
            throw CloudErrorMapper.database(error)
        }
    }

    func update<Row: Encodable>(
        table: String,
        match: [URLQueryItem],
        row: Row
    ) async throws {
        try await authorize()
        do {
            let builder = try client.from(table).update(row, returning: .minimal)
            Self.apply(match, to: builder)
            builder.retry(enabled: retryEnabled)
            try await builder.execute()
        } catch {
            throw CloudErrorMapper.database(error)
        }
    }

    func deleteNotIn(
        table: String,
        keepIds: [String],
        extraFilters: [URLQueryItem] = []
    ) async throws {
        try await authorize()
        let builder = client.from(table).delete(returning: .minimal)
        Self.apply(extraFilters, to: builder)
        if keepIds.isEmpty {
            _ = builder.filter("id", operator: "not.is", value: "null")
        } else {
            _ = builder.notIn("id", values: keepIds)
        }
        builder.retry(enabled: retryEnabled)

        do {
            try await builder.execute()
        } catch {
            throw CloudErrorMapper.database(error)
        }
    }

    func insertIgnoringDuplicates<Row: Encodable>(
        table: String,
        rows: [Row]
    ) async throws {
        guard !rows.isEmpty else { return }
        try await authorize()
        do {
            let builder = try client.from(table).upsert(
                try Self.normalizedBulkRows(rows),
                returning: .minimal,
                ignoreDuplicates: true
            )
            builder.retry(enabled: retryEnabled)
            try await builder.execute()
        } catch {
            throw CloudErrorMapper.database(error)
        }
    }

    static func normalizedBulkRows<Row: Encodable>(
        _ rows: [Row]
    ) throws -> [[String: AnyJSON]] {
        let data = try JSONEncoder().encode(rows)
        var objects = try JSONDecoder().decode([[String: AnyJSON]].self, from: data)
        let keys = Set(objects.flatMap(\.keys))
        for index in objects.indices {
            for key in keys where objects[index][key] == nil {
                objects[index][key] = .null
            }
        }
        return objects
    }

    private func authorize() async throws {
        do {
            _ = try await tokenProvider.validToken()
        } catch {
            throw CloudError.unauthorized
        }
    }

    private static func apply(
        _ items: [URLQueryItem],
        to builder: PostgrestFilterBuilder
    ) {
        for item in items {
            guard let value = item.value else { continue }
            switch item.name {
            case "select":
                continue
            case "order":
                for order in value.split(separator: ",") {
                    let parts = order.split(separator: ".")
                    guard let column = parts.first else { continue }
                    _ = builder.order(
                        String(column),
                        ascending: parts.dropFirst().first != "desc",
                        nullsFirst: parts.contains("nullsfirst")
                    )
                }
            case "limit":
                if let limit = Int(value) {
                    _ = builder.limit(limit)
                }
            default:
                guard let separator = value.firstIndex(of: ".") else {
                    _ = builder.filter(item.name, operator: "eq", value: value)
                    continue
                }
                _ = builder.filter(
                    item.name,
                    operator: String(value[..<separator]),
                    value: String(value[value.index(after: separator)...])
                )
            }
        }
    }
}

nonisolated enum CloudErrorMapper {
    static func database(_ error: Error) -> CloudError {
        if let cloud = error as? CloudError {
            return cloud
        }
        if error is CancellationError {
            return .network
        }
        if error is URLError {
            return .network
        }
        if let error = error as? HTTPError {
            let status = error.response.statusCode
            if status == 401 || status == 403 {
                return .unauthorized
            }
            return .remote(
                code: String(status),
                message: String(data: error.data, encoding: .utf8) ?? "HTTP \(status)"
            )
        }
        if let error = error as? PostgrestError {
            if ["42501", "PGRST301", "PGRST302"].contains(error.code) {
                return .unauthorized
            }
            return .remote(code: error.code ?? "postgrest", message: error.message)
        }
        if error is DecodingError {
            return .remote(code: "decode", message: error.localizedDescription)
        }
        return .remote(code: "unknown", message: error.localizedDescription)
    }

    static func function(_ error: Error) -> CloudError {
        if error is CancellationError || error is URLError {
            return .network
        }
        if let error = error as? FunctionsError {
            switch error {
            case .relayError:
                return .remote(code: "relay", message: error.localizedDescription)
            case .httpError(let code, let data):
                if code == 401 || code == 403 {
                    return .unauthorized
                }
                return .remote(
                    code: String(code),
                    message: String(data: data, encoding: .utf8) ?? "HTTP \(code)"
                )
            }
        }
        if error is DecodingError {
            return .remote(code: "decode", message: error.localizedDescription)
        }
        return .remote(code: "unknown", message: error.localizedDescription)
    }
}
