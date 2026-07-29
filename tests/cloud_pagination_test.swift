import Foundation

// Logic test for `CloudPagination` — the Issue #30 fix that stops a truncated
// cloud read from being used as the authority for deleting cloud rows.
//
// The stub "server" below is a plain in-memory table that honours the keyset
// cursor exactly the way PostgREST does (`id > cursor ORDER BY id LIMIT n`),
// plus a `max_rows` cap that silently truncates any page larger than it — the
// server behaviour that made the bug invisible in the first place.
//
// Coverage:
//   1. 1001 and 2001 rows are pulled in full through the paging loop, in id
//      order, with no gaps and no duplicates (the acceptance criterion).
//   2. `max_rows` truncation of an over-large page cannot produce a
//      false-complete result: the page size we send stays under the server cap.
//   3. a row inserted mid-scan below the cursor is missed but never duplicated,
//      and one inserted above the cursor is picked up — the keyset guarantee.
//   4. a server that ignores the cursor yields isComplete == false rather than
//      a duplicate-laden "complete" result.
//   5. pruneAll deletes exactly cloud-minus-local, in `deleteBatchSize` chunks,
//      and reports what it deleted.
//   6. pruneAll issues ZERO delete requests when any listing fails, including
//      when the failure is on a later table than one that already listed fine.
//   7. pruneAll refuses (throws) rather than deleting from a listing that did
//      not reach EOF.
//   8. an empty diff costs zero delete requests.
//   9. a keep-set derived from a TRUNCATED cloud read disables the prune
//      entirely — not one listing, not one delete (the Issue #30 headline: the
//      1001st row must not be deletable just because the read stopped at 1000).
//  10. a prune that fails partway through still reports every delete batch
//      that already landed — those rows are gone and nothing else can name
//      them afterwards.
//
// Compile with:
//   swiftc -parse-as-library \
//     PeakLog/Services/Cloud/CloudPagination.swift \
//     tests/cloud_pagination_test.swift -o /tmp/cpg && /tmp/cpg

@main
struct CloudPaginationTest {
    static func main() async {
        await testPullsPastMaxRowsInFull()
        await testPageSizeStaysUnderServerCap()
        await testConcurrentInsertNeitherSkipsNorDuplicates()
        await testCursorIgnoringServerReportsIncomplete()
        await testPruneDeletesOnlyTheDifferenceInBoundedBatches()
        await testPruneSendsNoDeleteWhenAnyListingFails()
        await testPruneRefusesTruncatedListing()
        await testPruneSendsNoDeleteWhenNothingIsDoomed()
        await testTruncatedKeepSetDisablesPruneEntirely()
        await testPartialPruneStillReportsCompletedBatches()
        print("cloud_pagination_test passed")
    }

    // MARK: - 1 & 2: reading past max_rows

    static func testPullsPastMaxRowsInFull() async {
        for total in [1001, 2001] {
            let server = StubTable(ids: (0..<total).map(Self.id))
            let result: CloudPagedResult<String>
            do {
                result = try await CloudPagination.fetchAll(key: { $0 }, page: server.page)
            } catch {
                fatalError("unexpected throw for \(total) rows: \(error)")
            }
            expect(result.isComplete, "\(total)-row read must reach EOF")
            expect(result.elements.count == total, "expected \(total) rows, got \(result.elements.count)")
            expect(Set(result.elements).count == total, "duplicate rows in a \(total)-row read")
            expect(result.elements == (0..<total).map(Self.id), "rows out of keyset order")
            // The whole point: a single unpaginated fetch would have stopped here.
            expect(total > StubTable.maxRows, "test fixture must exceed the server cap")
        }
    }

    static func testPageSizeStaysUnderServerCap() async {
        // If pageSize ever crept above max_rows, a capped page would come back
        // *short* relative to what we asked for and the loop would call EOF
        // early — silently reintroducing Issue #30. Assert the invariant.
        expect(
            CloudPagination.pageSize < StubTable.maxRows,
            "pageSize \(CloudPagination.pageSize) must stay below PostgREST max_rows \(StubTable.maxRows)"
        )
        let server = StubTable(ids: (0..<1200).map(Self.id))
        let result = try! await CloudPagination.fetchAll(key: { $0 }, page: server.page)
        expect(result.isComplete && result.elements.count == 1200, "capped-page read lost rows")
    }

    // MARK: - 3: concurrency

    static func testConcurrentInsertNeitherSkipsNorDuplicates() async {
        // 700 rows => two pages at pageSize 500, so page 1 leaves the cursor at
        // id-00499. Between the two pages we insert one row *below* the cursor
        // (id-00250a) and one *above* it (id-99999). Keyset guarantees: no
        // duplicates ever, the above-cursor row is seen, the below-cursor row
        // may be missed — and missing it is exactly why a snapshot alone may
        // never authorise a delete.
        let server = StubTable(ids: (0..<700).map(Self.id))
        server.insertAfterPage(1, ids: ["id-00250a", "id-99999"])

        let result = try! await CloudPagination.fetchAll(key: { $0 }, page: server.page)

        expect(result.isComplete, "concurrent-insert read must still reach EOF")
        expect(Set(result.elements).count == result.elements.count, "keyset pagination produced a duplicate")
        expect(result.elements.contains("id-99999"), "row inserted above the cursor must be picked up")
        expect(!result.elements.contains("id-00250a"), "row inserted below the cursor is expected to be missed")
        for original in (0..<700).map(Self.id) {
            expect(result.elements.contains(original), "pre-existing row \(original) was skipped")
        }
    }

    static func testCursorIgnoringServerReportsIncomplete() async {
        // A server that returns page 1 forever. Without the dedup + maxPages
        // stop this would either loop forever or return 500 × maxPages rows
        // that look complete.
        let ids = (0..<CloudPagination.pageSize).map(Self.id)
        let result = try! await CloudPagination.fetchAll(
            maxPages: 5,
            key: { $0 },
            page: { _, limit in Array(ids.prefix(limit)) }
        )
        expect(!result.isComplete, "a cursor-ignoring server must yield an INCOMPLETE result")
        expect(result.elements.count == CloudPagination.pageSize, "dedup should collapse the repeated page")
    }

    // MARK: - 5 & 8: prune diff

    static func testPruneDeletesOnlyTheDifferenceInBoundedBatches() async {
        let cloudIds = (0..<250).map(Self.id)
        let keep = Array(cloudIds.prefix(100))
        let recorder = DeleteRecorder()

        let outcomes = try! await CloudPagination.pruneAll(
            targets: [CloudPruneTarget(table: "exercise_sets", keepIds: keep)],
            keepIdsAreComplete: true,
            listCloudIds: { _ in CloudPagedResult(elements: cloudIds, isComplete: true) },
            deleteBatch: { target, ids in await recorder.record(table: target.table, ids: ids) }
        )

        let deleted = await recorder.allIds
        expect(deleted == Array(cloudIds.dropFirst(100)), "prune deleted the wrong set")
        expect(outcomes.count == 1 && outcomes[0].deletedIds.count == 150, "prune outcome misreported")

        let batches = await recorder.batches
        expect(batches.count == 2, "150 ids at batchSize \(CloudPagination.deleteBatchSize) should be 2 requests, got \(batches.count)")
        for batch in batches {
            expect(batch.ids.count <= CloudPagination.deleteBatchSize, "batch exceeded the URL bound")
        }
    }

    static func testPruneSendsNoDeleteWhenNothingIsDoomed() async {
        let recorder = DeleteRecorder()
        let outcomes = try! await CloudPagination.pruneAll(
            targets: [CloudPruneTarget(table: "workout_sessions", keepIds: ["a", "b"])],
            keepIdsAreComplete: true,
            listCloudIds: { _ in CloudPagedResult(elements: ["a", "b"], isComplete: true) },
            deleteBatch: { target, ids in await recorder.record(table: target.table, ids: ids) }
        )
        expect(outcomes.isEmpty, "a matching cloud should produce no prune outcome")
        expect(await recorder.batches.isEmpty, "a matching cloud must cost zero DELETE requests")
    }

    // MARK: - 6 & 7: zero DELETE on a bad read

    static func testPruneSendsNoDeleteWhenAnyListingFails() async {
        // The failing table is the SECOND one, after the first listed fine and
        // has doomed rows — the case a per-table list-then-delete loop would
        // get wrong by deleting table one before discovering table two is down.
        let recorder = DeleteRecorder()
        do {
            _ = try await CloudPagination.pruneAll(
                targets: [
                    CloudPruneTarget(table: "exercise_sets", keepIds: []),
                    CloudPruneTarget(table: "workout_sessions", keepIds: [])
                ],
                keepIdsAreComplete: true,
                listCloudIds: { target in
                    if target.table == "workout_sessions" { throw StubError.network }
                    return CloudPagedResult(elements: ["doomed-1"], isComplete: true)
                },
                deleteBatch: { target, ids in await recorder.record(table: target.table, ids: ids) }
            )
            fatalError("expected the listing failure to propagate")
        } catch StubError.network {
        } catch {
            fatalError("unexpected error: \(error)")
        }
        expect(await recorder.batches.isEmpty, "a mid-read failure must leave the cloud untouched")
    }

    static func testPruneRefusesTruncatedListing() async {
        let recorder = DeleteRecorder()
        do {
            _ = try await CloudPagination.pruneAll(
                targets: [CloudPruneTarget(table: "exercise_sets", keepIds: [])],
                keepIdsAreComplete: true,
                listCloudIds: { _ in CloudPagedResult(elements: ["doomed-1"], isComplete: false) },
                deleteBatch: { target, ids in await recorder.record(table: target.table, ids: ids) }
            )
            fatalError("expected a truncated listing to be refused")
        } catch CloudPaginationError.incompleteListing(let table) {
            expect(table == "exercise_sets", "wrong table named in the refusal")
        } catch {
            fatalError("unexpected error: \(error)")
        }
        expect(await recorder.batches.isEmpty, "a truncated listing must cost zero DELETE requests")
    }

    static func testTruncatedKeepSetDisablesPruneEntirely() async {
        // The local cache was built from a read that stopped at row 1000, so
        // rows 1001+ are absent from `keepIds` purely because we never saw
        // them. Every one of them would otherwise be diffed as "deleted".
        let recorder = DeleteRecorder()
        let listings = ListingCounter()

        let outcomes = try! await CloudPagination.pruneAll(
            targets: [
                CloudPruneTarget(table: "exercise_sets", keepIds: (0..<1000).map(Self.id)),
                CloudPruneTarget(table: "workout_sessions", keepIds: [])
            ],
            keepIdsAreComplete: false,
            listCloudIds: { _ in
                await listings.bump()
                return CloudPagedResult(elements: (0..<2001).map(Self.id), isComplete: true)
            },
            deleteBatch: { target, ids in await recorder.record(table: target.table, ids: ids) }
        )

        expect(outcomes.isEmpty, "a truncated keep set must produce no prune outcome")
        expect(await recorder.batches.isEmpty, "a truncated keep set must cost zero DELETE requests")
        expect(await listings.count == 0, "a disabled prune should not even list the cloud")
    }

    // MARK: - 10: the audit trail survives a partial prune

    static func testPartialPruneStillReportsCompletedBatches() async {
        // 250 doomed ids => 3 batches; the third fails. The first two are
        // already gone from the cloud and can never be reconstructed, so the
        // deletion log has to name them even though `pruneAll` throws and its
        // return value is discarded.
        let recorder = DeleteRecorder()
        let audit = OutcomeLog()
        let doomed = (0..<250).map(Self.id)

        do {
            _ = try await CloudPagination.pruneAll(
                targets: [CloudPruneTarget(table: "exercise_sets", keepIds: [])],
                keepIdsAreComplete: true,
                listCloudIds: { _ in CloudPagedResult(elements: doomed, isComplete: true) },
                deleteBatch: { target, ids in
                    if ids.contains(Self.id(200)) { throw StubError.network }
                    await recorder.record(table: target.table, ids: ids)
                },
                didDelete: { audit.append($0) }
            )
            fatalError("expected the third delete batch to propagate its failure")
        } catch StubError.network {
        } catch {
            fatalError("unexpected error: \(error)")
        }

        let reported = audit.allIds
        let actuallyDeleted = await recorder.allIds
        expect(actuallyDeleted == Array(doomed.prefix(200)), "fixture should have deleted exactly two batches")
        expect(reported == actuallyDeleted, "the audit log must name every row the prune actually destroyed")
        expect(audit.outcomes.allSatisfy { $0.table == "exercise_sets" }, "audit entries lost their table")
    }

    // MARK: - helpers

    static func id(_ index: Int) -> String { "id-" + String(format: "%05d", index) }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { fatalError(message()) }
    }
}

private enum StubError: Error { case network }

/// An in-memory stand-in for one PostgREST table: honours `id > cursor
/// ORDER BY id LIMIT n`, and applies the same silent `max_rows` cap the real
/// server does.
private final class StubTable: @unchecked Sendable {
    /// Mirrors `backend/supabase/config.toml` → `max_rows = 1000`.
    static let maxRows = 1000

    private var ids: [String]
    private var pageCount = 0
    private var deferredInserts: [Int: [String]] = [:]

    init(ids: [String]) { self.ids = ids.sorted() }

    /// Rows that land only once `page` has already been served that many
    /// times — a concurrent writer committing mid-scan. Keyed by the page
    /// number they become visible to, i.e. the one after.
    func insertAfterPage(_ page: Int, ids newIds: [String]) {
        deferredInserts[page + 1, default: []].append(contentsOf: newIds)
    }

    var page: @Sendable (String?, Int) async throws -> [String] {
        { [self] after, limit in
            pageCount += 1
            if let pending = deferredInserts.removeValue(forKey: pageCount) {
                ids = (ids + pending).sorted()
            }
            let window = after.map { cursor in ids.filter { $0 > cursor } } ?? ids
            return Array(window.prefix(Swift.min(limit, Self.maxRows)))
        }
    }
}

private actor ListingCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// Collects the `didDelete` callback. A lock rather than an actor because the
/// callback is synchronous — which is the point: it has to finish recording
/// before the next batch is attempted.
private final class OutcomeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CloudPruneOutcome] = []

    func append(_ outcome: CloudPruneOutcome) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(outcome)
    }

    var outcomes: [CloudPruneOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var allIds: [String] { outcomes.flatMap(\.deletedIds) }
}

private actor DeleteRecorder {
    struct Batch { let table: String; let ids: [String] }
    private(set) var batches: [Batch] = []

    func record(table: String, ids: [String]) { batches.append(Batch(table: table, ids: ids)) }
    var allIds: [String] { batches.flatMap(\.ids) }
}
