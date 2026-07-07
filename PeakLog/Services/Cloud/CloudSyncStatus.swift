import Foundation

/// User-visible sync state. Exists because the write model is local-first: a
/// mutation's `await` only waits on the local write (instant, no network), so
/// without this the cloud push happening in the background would be entirely
/// invisible — a user could train for days offline and never know their data
/// wasn't backed up. Surfaced minimally in `ProfileScreen`.
nonisolated enum CloudSyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case pendingRetry(String)
}
