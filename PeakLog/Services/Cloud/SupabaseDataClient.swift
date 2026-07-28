import Foundation
import Supabase

nonisolated enum CloudError: Error, Equatable, Sendable {
    case notConfigured
    case network
    case unauthorized
    case remote(code: String, message: String)
}

nonisolated struct SupabaseDataClient: Sendable {
    private let apiClient: SupabaseAPIClient
    private let tokenProvider: TokenProviding
    private let retryEnabled: Bool

    init(
        client: SupabaseAPIClient,
        tokenProvider: TokenProviding,
        retryEnabled: Bool = true
    ) {
        self.apiClient = client
        self.tokenProvider = tokenProvider
        self.retryEnabled = retryEnabled
    }

    /// Single-request fetch. Only safe for reads that are bounded by
    /// construction — one row per user (`profiles`, `user_preferences`,
    /// `user_goal_specs`), an explicit `limit`, or a projection the caller
    /// knows cannot grow. Anything that grows with training history must use
    /// `fetchAllPages`, or PostgREST's `max_rows` truncates it silently.
    func fetch<Row: Decodable>(
        _ type: Row.Type,
        table: String,
        query: [URLQueryItem]
    ) async throws -> [Row] {
        do {
            return try await apiClient.withAuthorization(using: tokenProvider) { client in
                let columns = query.first(where: { $0.name == "select" })?.value ?? "*"
                let builder = client.from(table).select(columns)
                Self.apply(query, to: builder)
                builder.retry(enabled: retryEnabled)
                let response: PostgrestResponse<[Row]> = try await builder.execute()
                return response.value
            }
        } catch {
            throw CloudErrorMapper.database(error)
        }
    }

    /// Fetch a whole table by keyset pagination on `id`, looping until
    /// PostgREST confirms EOF (see `CloudPagination.fetchAll` for why keyset
    /// and not offset/range).
    ///
    /// `query` supplies the caller's own filters (e.g. the active-plan scope);
    /// the cursor, ordering and limit are appended here, so callers must not
    /// pass their own `order` or `limit` — `apply` would emit both and the
    /// cursor would no longer match the sort.
    ///
    /// The result carries `isComplete`; a `false` there means the page cap
    /// stopped us mid-table and the rows are a prefix.
    func fetchAllPages<Row: Decodable & Sendable>(
        _ type: Row.Type,
        table: String,
        query: [URLQueryItem] = [],
        pageSize: Int = CloudPagination.pageSize,
        key: @escaping @Sendable (Row) -> String
    ) async throws -> CloudPagedResult<Row> {
        try await CloudPagination.fetchAll(pageSize: pageSize, key: key) { after, limit in
            var pageQuery = query
            if let after {
                pageQuery.append(URLQueryItem(name: "id", value: "gt.\(after)"))
            }
            pageQuery.append(URLQueryItem(name: "order", value: "id.asc"))
            pageQuery.append(URLQueryItem(name: "limit", value: String(limit)))
            return try await self.fetch(type, table: table, query: pageQuery)
        }
    }

    func upsert<Row: Encodable>(table: String, rows: [Row]) async throws {
        guard !rows.isEmpty else { return }
        do {
            try await apiClient.withAuthorization(using: tokenProvider) { client in
                let builder = try client
                    .from(table)
                    .upsert(try Self.normalizedBulkRows(rows), returning: .minimal)
                builder.retry(enabled: retryEnabled)
                try await builder.execute()
            }
        } catch {
            throw CloudErrorMapper.database(error)
        }
    }

    func update<Row: Encodable>(
        table: String,
        match: [URLQueryItem],
        row: Row
    ) async throws {
        do {
            try await apiClient.withAuthorization(using: tokenProvider) { client in
                let builder = try client.from(table).update(row, returning: .minimal)
                Self.apply(match, to: builder)
                builder.retry(enabled: retryEnabled)
                try await builder.execute()
            }
        } catch {
            throw CloudErrorMapper.database(error)
        }
    }

    /// Read a table's full id set (within `filters`) as a paginated,
    /// completeness-tagged listing. `select=id` keeps this ~36 bytes per row
    /// on the wire, so listing a large history costs far less than the row
    /// fetch the snapshot loader already does.
    func listIds(table: String, filters: [URLQueryItem] = []) async throws -> CloudPagedResult<String> {
        try await fetchAllPages(
            CloudIdRow.self,
            table: table,
            query: filters + [URLQueryItem(name: "select", value: "id")],
            key: { $0.id }
        ).map(\.id)
    }

    /// Reconcile the destructive half of a push across every target: delete
    /// each table's rows that the cloud has and `keepIds` does not.
    ///
    /// This replaced per-table `DELETE … id=not.in.(<all local ids>)` calls,
    /// which (a) put an unbounded id list in the URL — Issue #39's 414 — and
    /// (b) issued a destructive request even when the id list they were built
    /// from was truncated. See `CloudPagination.pruneAll` for the two-phase
    /// protocol and why chunking the old filter would have been unsound.
    ///
    /// - Parameter keepIdsAreComplete: false when the local cache behind
    ///   `keepIds` came from a truncated cloud read, in which case nothing is
    ///   listed or deleted at all. See `CloudPagination.pruneAll`.
    /// - Returns: what was deleted, per table, for the caller to log.
    @discardableResult
    func prune(
        targets: [CloudPruneTarget],
        keepIdsAreComplete: Bool = true
    ) async throws -> [CloudPruneOutcome] {
        try await CloudPagination.pruneAll(
            targets: targets,
            keepIdsAreComplete: keepIdsAreComplete,
            listCloudIds: { target in
                try await self.listIds(table: target.table, filters: target.filters)
            },
            deleteBatch: { target, ids in
                try await self.deleteIds(table: target.table, ids: ids, extraFilters: target.filters)
            }
        )
    }

    /// Delete an explicit id list, chunked so the query string stays short.
    /// Batches are sequential on purpose: a failure leaves the earlier batches
    /// deleted and the rest alone, which is the same partial-progress model
    /// the rest of the push already has (a retry re-computes the diff).
    ///
    /// Chunking is applied here as well as in `CloudPagination.pruneAll` so
    /// that callers reaching this directly with an explicit delete list — the
    /// tombstone path — get the same URL bound without having to remember it.
    func deleteIds(
        table: String,
        ids: [String],
        extraFilters: [URLQueryItem] = []
    ) async throws {
        guard !ids.isEmpty else { return }
        for batch in CloudPagination.batched(ids) {
            do {
                try await apiClient.withAuthorization(using: tokenProvider) { client in
                    let builder = client.from(table).delete(returning: .minimal)
                    Self.apply(extraFilters, to: builder)
                    _ = builder.in("id", values: batch)
                    builder.retry(enabled: retryEnabled)
                    try await builder.execute()
                }
            } catch {
                throw CloudErrorMapper.database(error)
            }
        }
    }

    func insertIgnoringDuplicates<Row: Encodable>(
        table: String,
        rows: [Row]
    ) async throws {
        guard !rows.isEmpty else { return }
        do {
            try await apiClient.withAuthorization(using: tokenProvider) { client in
                let builder = try client.from(table).upsert(
                    try Self.normalizedBulkRows(rows),
                    returning: .minimal,
                    ignoreDuplicates: true
                )
                builder.retry(enabled: retryEnabled)
                try await builder.execute()
            }
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
        if error is SupabaseAPIAuthorizationError {
            return .unauthorized
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
        if error is SupabaseAPIAuthorizationError {
            return .unauthorized
        }
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
