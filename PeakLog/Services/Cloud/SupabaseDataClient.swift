import Foundation

nonisolated enum CloudError: Error, Sendable {
    case notConfigured
    case network
    case unauthorized
    case http(status: Int, body: String)
}

/// A thin PostgREST client. Every request carries the publishable key plus a
/// fresh user JWT (per-request, so token refresh is transparent); RLS scopes
/// all rows to the signed-in user server-side. Kept deliberately small — three
/// verbs cover the whole sync: read a table, upsert rows, prune rows.
nonisolated struct SupabaseDataClient: Sendable {
    private let config: SupabaseConfig
    private let tokenProvider: TokenProviding
    private let session: URLSession

    init(config: SupabaseConfig = .current, tokenProvider: TokenProviding, session: URLSession = .shared) {
        self.config = config
        self.tokenProvider = tokenProvider
        self.session = session
    }

    // MARK: - Read

    /// Select rows from `table`, applying raw PostgREST query items (e.g.
    /// `select=*`, `order=created_at.asc`). RLS handles the `user_id` filter.
    func fetch<Row: Decodable>(_ type: Row.Type, table: String, query: [URLQueryItem]) async throws -> [Row] {
        var items = query
        if !items.contains(where: { $0.name == "select" }) {
            items.append(URLQueryItem(name: "select", value: "*"))
        }
        let request = try await makeRequest(table: table, method: "GET", queryItems: items)
        let data = try await send(request)
        do {
            return try JSONDecoder().decode([Row].self, from: data)
        } catch {
            throw CloudError.http(status: 200, body: "decode failed: \(error)")
        }
    }

    // MARK: - Write

    /// Insert-or-update `rows` by primary key. No-op for an empty batch.
    func upsert<Row: Encodable>(table: String, rows: [Row]) async throws {
        guard !rows.isEmpty else { return }
        var request = try await makeRequest(table: table, method: "POST", queryItems: [])
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try Self.normalizedBulkBody(rows)
        _ = try await send(request)
    }

    /// PostgREST rejects a bulk payload whose objects don't all carry the same
    /// key set (PGRST102 "All object keys must match"), and the server predates
    /// `Prefer: missing=default` — while Swift's synthesized `Encodable` omits
    /// nil optionals, so two rows of the same type can encode different key
    /// sets (e.g. a plan day with `focus` next to a rest day without; the bug
    /// that silently failed every plan push). Normalize: union the keys across
    /// rows and fill each row's gaps with explicit JSON `null`, which is what
    /// the omitted optional means here (full-state reconcile: nil is the local
    /// truth for that column). A key omitted by *every* row (e.g.
    /// `training_plans.revision`, deliberately never encoded) stays omitted,
    /// preserving its untouched-on-conflict semantics.
    static func normalizedBulkBody<Row: Encodable>(_ rows: [Row]) throws -> Data {
        let encoded = try JSONEncoder().encode(rows)
        guard rows.count > 1,
              let objects = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        else { return encoded }

        var allKeys = Set<String>()
        for object in objects { allKeys.formUnion(object.keys) }
        guard objects.contains(where: { $0.count != allKeys.count }) else { return encoded }

        let filled = objects.map { object -> [String: Any] in
            var object = object
            for key in allKeys where object[key] == nil { object[key] = NSNull() }
            return object
        }
        return try JSONSerialization.data(withJSONObject: filled)
    }

    /// PATCH the row(s) matched by `match`. Used for tables that already have a
    /// trigger-created row and whose RLS forbids INSERT (e.g. `profiles`, which
    /// has only SELECT/UPDATE policies) or whose unique key isn't the PK we
    /// carry (e.g. `user_preferences`, unique on `user_id`). Upserting those
    /// would 403 / 409; an update is the correct verb.
    func update<Row: Encodable>(table: String, match: [URLQueryItem], row: Row) async throws {
        var request = try await makeRequest(table: table, method: "PATCH", queryItems: match)
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(row)
        _ = try await send(request)
    }

    /// Delete this user's rows in `table` whose id is not in `keepIds`. An empty
    /// `keepIds` deletes every row matched by `extraFilters` (or, with no
    /// filters at all, every row the user owns in the table).
    ///
    /// `extraFilters` narrows which rows are even candidates for deletion —
    /// e.g. `plan_id=eq.<active>` so pruning a plan's child rows never
    /// touches a different (archived) plan's rows sitting in the same table.
    func deleteNotIn(table: String, keepIds: [String], extraFilters: [URLQueryItem] = []) async throws {
        var items = extraFilters
        if keepIds.isEmpty {
            items.append(URLQueryItem(name: "id", value: "not.is.null"))
        } else {
            let list = keepIds.map { "\"\($0)\"" }.joined(separator: ",")
            items.append(URLQueryItem(name: "id", value: "not.in.(\(list))"))
        }
        var request = try await makeRequest(table: table, method: "DELETE", queryItems: items)
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        _ = try await send(request)
    }

    /// Insert `rows`, silently skipping any that already exist (matched by
    /// primary key). For append-only tables like `plan_edit_events`, whose RLS
    /// deliberately grants no UPDATE policy: unlike `upsert`'s
    /// `ON CONFLICT DO UPDATE` (which needs UPDATE privilege even when no row
    /// actually conflicts), `DO NOTHING` needs only INSERT — and makes a
    /// retried push of the same client-generated ids idempotent.
    func insertIgnoringDuplicates<Row: Encodable>(table: String, rows: [Row]) async throws {
        guard !rows.isEmpty else { return }
        var request = try await makeRequest(table: table, method: "POST", queryItems: [])
        request.setValue("resolution=ignore-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try Self.normalizedBulkBody(rows)
        _ = try await send(request)
    }

    // MARK: - Plumbing

    private func makeRequest(table: String, method: String, queryItems: [URLQueryItem]) async throws -> URLRequest {
        let base = config.url.appendingPathComponent("rest/v1").appendingPathComponent(table)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw CloudError.notConfigured
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw CloudError.notConfigured }

        let token: String
        do {
            token = try await tokenProvider.validToken()
        } catch {
            throw CloudError.unauthorized
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudError.network
        }
        guard let http = response as? HTTPURLResponse else { throw CloudError.network }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw CloudError.unauthorized
        default:
            throw CloudError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
