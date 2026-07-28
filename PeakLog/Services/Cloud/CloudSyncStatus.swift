import Foundation

/// Internal/diagnostic sync state. **Must not be shown to the user** — see
/// Issue #102.
///
/// It once existed to be displayed: the write model is local-first, a
/// mutation's `await` only waits on the local write (instant, no network), so
/// the cloud push happening afterwards in the background is otherwise
/// invisible — a user could train for days offline and never know their data
/// wasn't backed up. That reasoning was overturned by a product decision: the
/// user cannot wait for, retry, or otherwise influence a background push, so
/// surfacing a failure raises anxiety without changing any outcome. Sync is
/// silent. `ProfileScreen`'s sync row was removed in PR #101 and does not
/// come back; the `profile.sync.idle` / `profile.sync.syncing` /
/// `profile.sync.pending_retry` strings are kept in the catalog but stay
/// unused.
///
/// What this leaves the enum for: it is the observable edge of the sync loop
/// for logging and in-process diagnostics (`CloudSyncCoordinator.diagnostics`,
/// the DEBUG E2E check). Read it from `Services/Cloud/`; do not bind it into a
/// view, banner, badge, or alert.
///
/// This does **not** weaken failure handling. `.pendingRetry` is a report, not
/// the retry mechanism — recovery runs off `CloudSyncCoordinator`'s
/// `hasUnpushedChanges` (persisted across launches), which `onForeground`
/// checks to re-push. A failed push still self-heals on the next foreground or
/// cold start whether or not anyone is listening to this enum.
///
/// The accepted cost: a deterministic push failure is invisible in the UI.
/// That risk is recorded in Issue #102 and deliberately taken. Failures are
/// still logged to Console.app under the `CloudSync` category.
///
/// `tests/silent_sync_contract_test.swift` enforces all of the above.
nonisolated enum CloudSyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case pendingRetry(String)
}
