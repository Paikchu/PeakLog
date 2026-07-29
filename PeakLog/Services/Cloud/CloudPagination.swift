import Foundation

/// Keyset pagination + the prune protocol built on top of it, expressed as
/// pure `async` algorithms over injected page/delete closures.
///
/// Why this lives in its own Foundation-only file: `SupabaseDataClient`
/// `import Supabase`, so nothing in it can be compiled by the standalone
/// `tests/` harness. The parts that actually carry the correctness risk here —
/// "did we reach EOF?", "is this result a truncated prefix?", "may we delete?"
/// — are pure logic, so they live here and the client only supplies the two
/// network closures. Same rationale as `LocalDataSnapshot.swift`.
nonisolated enum CloudPagination {
    /// Page size for every paginated read. Deliberately below PostgREST's
    /// `max_rows` (`backend/supabase/config.toml` → 1000): the server silently
    /// caps any larger `limit`, and a page that came back capped rather than
    /// short would be indistinguishable from a full page — the loop would
    /// still terminate correctly, but only because of server config we don't
    /// control from the client. Staying under it keeps "short page ⇒ EOF" a
    /// property of our own request.
    static let pageSize = 500

    /// Hard stop for the paging loop. 500 × 400 = 200k rows per table, far
    /// beyond any realistic single-user training history, so hitting it means
    /// something is wrong (a server ignoring the cursor, a writer appending
    /// faster than we read). We stop and report the result as INCOMPLETE
    /// rather than loop forever or — much worse — hand a truncated prefix to
    /// the prune path.
    static let maxPages = 400

    /// Ids per DELETE request. Each id is a 36-char UUID plus separator and
    /// quoting, so 100 ids ≈ 4 KB of query string — an order of magnitude
    /// under any proxy/PostgREST URL limit (Issue #39's 414).
    static let deleteBatchSize = 100

    /// Fetch every page of a table using **keyset (cursor) pagination** on the
    /// caller-supplied key.
    ///
    /// Why keyset and not `range`/`offset`: offset pagination re-evaluates the
    /// same sorted result set on every request, so a row inserted or deleted
    /// *before* the current offset while we page shifts every later row —
    /// producing a skipped or duplicated row. A cursor (`key > lastSeenKey`,
    /// ordered by the same key) is immune: the window is defined by a value,
    /// not by a position.
    ///
    /// The key must be **unique, immutable and totally ordered** — callers pass
    /// the primary key `id`. It is the only column every synced table has
    /// (`exercises`, `exercise_sets` and the plan child tables carry no
    /// user-facing sort column), it is never null, and rows never change id, so
    /// no row can move across the cursor mid-scan. A `(created_at, id)`
    /// composite would also be stable but buys nothing here — result order is
    /// irrelevant because `CloudMapper.assembleSnapshot` re-nests and re-sorts
    /// by `day_index` / `order_index` / `set_index` anyway.
    ///
    /// Guarantee under concurrent writes: every row that existed when the
    /// first page was issued and still exists when the last one returns is
    /// yielded **exactly once** — no gaps, no duplicates. Rows *inserted
    /// concurrently* may or may not appear: ids are random UUIDs, so one
    /// inserted below the cursor after we passed it is simply missed, and the
    /// scan still reports `isComplete` because a later page came back short.
    ///
    /// That last sentence is the whole reason `pruneAll` takes an
    /// `observedIds` set. A read reaching EOF proves "we saw the end of the
    /// table", **not** "we saw every row that is in it now" — so `isComplete`
    /// alone can never authorise a delete. Deleting is restricted to rows this
    /// scan actually returned; a row it missed is, by construction, a row we
    /// have no opinion about.
    ///
    /// - Throws: whatever `page` throws. A mid-scan failure aborts the whole
    ///   read instead of returning a short result a caller might mistake for
    ///   EOF.
    static func fetchAll<Element: Sendable>(
        pageSize: Int = pageSize,
        maxPages: Int = maxPages,
        key: @Sendable (Element) -> String,
        page: @Sendable (_ after: String?, _ limit: Int) async throws -> [Element]
    ) async throws -> CloudPagedResult<Element> {
        var elements: [Element] = []
        var seenKeys: Set<String> = []
        var cursor: String?

        for _ in 0..<max(maxPages, 1) {
            let batch = try await page(cursor, pageSize)
            // Dedup is not needed against a server that honours the cursor; it
            // is here so a server that silently ignores it degrades into "same
            // page forever ⇒ maxPages ⇒ isComplete == false" instead of
            // returning a plausible-looking result full of duplicates.
            for element in batch where seenKeys.insert(key(element)).inserted {
                elements.append(element)
            }
            // A short page is PostgREST telling us there is nothing after it.
            // An exactly-full final page costs one extra empty request, which
            // also lands here — cheap, and it removes the "was that EOF?"
            // ambiguity entirely.
            if batch.count < pageSize {
                return CloudPagedResult(elements: elements, isComplete: true)
            }
            // Safe to force-index: a batch reaching `pageSize` is non-empty,
            // and the branch above already returned for short/empty ones.
            cursor = key(batch[batch.index(before: batch.endIndex)])
        }

        return CloudPagedResult(elements: elements, isComplete: false)
    }

    /// The destructive half of a full-state reconcile, as an explicit
    /// **list-diff-then-delete-by-id** protocol run in two strictly separated
    /// phases across *all* tables.
    ///
    /// Replaces "`DELETE … WHERE id NOT IN (<every local id>)`", which had two
    /// defects: it put an unbounded id list in the URL (Issue #39 → 414), and
    /// it expressed deletion as *absence*, so any row the local snapshot
    /// happened not to know about — because the read was truncated (Issue #30)
    /// or because another device added it (Issue #132) — was deleted.
    ///
    /// Chunking the old filter was not an option: `NOT IN (A ∪ B)` is not
    /// `NOT IN (A)` followed by `NOT IN (B)` — the first request would delete
    /// everything in B. Bounding the URL therefore *requires* naming the doomed
    /// rows, which requires reading the cloud id set first.
    ///
    /// Phase 1 lists every target's cloud ids; phase 2 issues the deletes.
    /// Splitting them across the whole target set (rather than per table) is
    /// what makes the guarantee "**a failure anywhere in the read half means
    /// zero DELETE requests were sent**" hold for a multi-table push, not just
    /// within one table. Once phase 2 starts a failure can leave earlier
    /// batches deleted — the same partial-progress model the upsert half
    /// already has, and a retry recomputes the diff.
    ///
    /// A prune diffs two sets, and **both** of them have to be provably
    /// complete or the difference is meaningless. The three incomplete cases
    /// are handled deliberately differently:
    ///
    /// - `keepIdsAreComplete == false` — the *local* side came from a
    ///   truncated cloud read, so rows past the cutoff are missing from it and
    ///   would look deleted (Issue #30). We return without listing or deleting
    ///   anything. Skipping is the self-healing direction: the cloud keeps
    ///   rows it should have dropped, and the next push after a complete read
    ///   drops them.
    /// - a listing that did not reach EOF — the *cloud* side is a prefix, so
    ///   we cannot even enumerate what to delete. That throws, because unlike
    ///   the case above it does not self-heal: it means a table blew past
    ///   `maxPages` and someone needs to know.
    /// - a row the snapshot read never returned — this is the one `isComplete`
    ///   cannot speak to at all. A keyset scan reaching EOF can still have
    ///   missed a row another device inserted below the cursor mid-scan, and
    ///   the fresh listing here *does* see it, so a plain `listed − keep` diff
    ///   deletes a valid concurrent write. `target.observedIds` fixes the
    ///   asymmetry: only rows the snapshot itself returned are eligible.
    ///
    /// - Parameter keepIdsAreComplete: whether every `keepIds` set was derived
    ///   from a cloud read that reached EOF on every table it covers.
    /// - Parameter targets: evaluated in order during phase 2, so callers can
    ///   put child tables before parents.
    /// - Parameter didDelete: called with each batch **the moment that batch
    ///   lands**, before the next one is attempted. The return value below is
    ///   only produced on the success path, so on a mid-prune failure it is
    ///   thrown away along with the record of every batch that already
    ///   succeeded — and those rows are gone from the cloud, so nothing can
    ///   reconstruct them afterwards. The callback is what makes the audit
    ///   trail survive exactly the partial failure it exists for.
    /// - Returns: per table, the ids actually deleted — empty in the normal
    ///   case, and the aggregated view of the same deletions the callback
    ///   already reported.
    @discardableResult
    static func pruneAll(
        targets: [CloudPruneTarget],
        keepIdsAreComplete: Bool,
        batchSize: Int = deleteBatchSize,
        listCloudIds: @Sendable (CloudPruneTarget) async throws -> CloudPagedResult<String>,
        deleteBatch: @Sendable (CloudPruneTarget, [String]) async throws -> Void,
        didDelete: @Sendable (CloudPruneOutcome) -> Void = { _ in }
    ) async throws -> [CloudPruneOutcome] {
        guard keepIdsAreComplete else { return [] }

        // Phase 1 — read only. Nothing destructive has been sent yet, so any
        // throw from here leaves the cloud untouched.
        var plans: [(target: CloudPruneTarget, doomed: [String])] = []
        for target in targets {
            let listed = try await listCloudIds(target)
            guard listed.isComplete else {
                throw CloudPaginationError.incompleteListing(table: target.table)
            }
            let keep = Set(target.keepIds)
            // "Present in the cloud and absent locally" is only evidence of a
            // deletion for rows the snapshot read actually handed us. A row it
            // never returned — because a concurrent insert landed below the
            // cursor — is absent from `keepIds` for a reason that has nothing
            // to do with the user, so it is not eligible no matter what the
            // listing says.
            plans.append((
                target,
                listed.elements.filter { target.observedIds.contains($0) && !keep.contains($0) }
            ))
        }

        // Phase 2 — destructive.
        var outcomes: [CloudPruneOutcome] = []
        for plan in plans where !plan.doomed.isEmpty {
            for batch in batched(plan.doomed, size: batchSize) {
                try await deleteBatch(plan.target, batch)
                didDelete(CloudPruneOutcome(table: plan.target.table, deletedIds: batch))
            }
            outcomes.append(CloudPruneOutcome(table: plan.target.table, deletedIds: plan.doomed))
        }
        return outcomes
    }

    /// Splits ids into URL-length-safe chunks. `size <= 0` degrades to one id
    /// per request rather than trapping — a misconfigured constant should cost
    /// requests, not crash a sync.
    static func batched(_ ids: [String], size: Int = deleteBatchSize) -> [[String]] {
        guard !ids.isEmpty else { return [] }
        guard size > 0 else { return ids.map { [$0] } }
        return stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<Swift.min($0 + size, ids.count)])
        }
    }
}

/// One table's share of a prune: which table, which ids survive, which ids are
/// even eligible to be destroyed, and the scoping filters that define the slice
/// being reconciled (e.g. the plan-child tables are only ever pruned within the
/// *active* plan, SY2).
///
/// The same `filters` must reach the listing and the deletes — a listing wider
/// than the delete would compute doomed rows the delete cannot reach; a
/// listing narrower than the delete would under-report what is about to be
/// destroyed.
nonisolated struct CloudPruneTarget: Sendable {
    let table: String
    let keepIds: [String]
    /// Ids this device has actually held in its hand: everything the snapshot
    /// read returned, plus everything a successful push of ours put there.
    /// A prune may only ever destroy rows from this set.
    ///
    /// There is no default. Omitting it would have to mean "anything the
    /// listing finds is fair game", which is the exact assumption that made a
    /// concurrent insert deletable — an unsafe default is worse than a
    /// required argument.
    let observedIds: Set<String>
    let filters: [URLQueryItem]

    init(
        table: String,
        keepIds: [String],
        observedIds: Set<String>,
        filters: [URLQueryItem] = []
    ) {
        self.table = table
        self.keepIds = keepIds
        self.observedIds = observedIds
        self.filters = filters
    }
}

/// What a prune actually destroyed, for the sync log. Deletion is the only
/// irreversible thing sync does, so it is the one thing worth being able to
/// reconstruct after the fact from a device's Console output.
nonisolated struct CloudPruneOutcome: Sendable {
    let table: String
    let deletedIds: [String]
}

/// A paginated read plus the one fact the destructive half of sync depends on:
/// did we actually reach the end of the table?
///
/// `isComplete == false` means `elements` is a *prefix*, not the table. Callers
/// may display it, but must never treat a row's absence from it as evidence
/// the row does not exist server-side.
nonisolated struct CloudPagedResult<Element: Sendable>: Sendable {
    let elements: [Element]
    let isComplete: Bool

    init(elements: [Element], isComplete: Bool) {
        self.elements = elements
        self.isComplete = isComplete
    }

    func map<Mapped: Sendable>(_ transform: (Element) -> Mapped) -> CloudPagedResult<Mapped> {
        CloudPagedResult<Mapped>(elements: elements.map(transform), isComplete: isComplete)
    }
}

nonisolated enum CloudPaginationError: Error, Equatable, LocalizedError {
    /// A prune was asked to run against a cloud id listing that did not reach
    /// EOF. Deleting from a prefix would delete every row past the cutoff, so
    /// this aborts the push instead — loudly, because reaching it means a
    /// table blew past `maxPages` and sync can no longer self-heal on its own.
    case incompleteListing(table: String)

    var errorDescription: String? {
        switch self {
        case .incompleteListing(let table):
            return "Cloud id listing for \(table) was truncated; prune refused."
        }
    }
}
