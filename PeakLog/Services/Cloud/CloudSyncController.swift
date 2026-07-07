import Foundation
import Combine

/// Bridges the `@MainActor` app/auth world to the background `CloudSyncCoordinator`.
/// Starts a coordinator when a user signs in, tears it down on sign-out or
/// DEBUG local mode, and forwards foreground ticks. Idempotent per user id so
/// repeated auth-state emissions don't restart an active sync.
@MainActor
final class CloudSyncController: ObservableObject {
    /// True from sign-in until the first pull finishes. The gate holds on a
    /// splash while this is set, so the main UI's first read sees cloud truth
    /// rather than the stale seed/local cache it would otherwise render.
    @Published private(set) var isPreparingSession = false

    /// User-visible sync state (see `CloudSyncStatus`). `.idle` while signed out
    /// or in DEBUG local mode — there is nothing to report.
    @Published private(set) var syncStatus: CloudSyncStatus = .idle

    private let database: LocalAppDatabase
    private var coordinator: CloudSyncCoordinator?
    private var activeUserId: String?
    private var stateSubscription: AnyCancellable?

    init(database: LocalAppDatabase = .shared) {
        self.database = database
    }

    /// Subscribe to auth-state changes. Combine delivers synchronously with the
    /// `@Published` mutation (unlike SwiftUI `.onChange`, which is deferred to
    /// the next view update) — so `isPreparingSession` flips and the coordinator
    /// starts *before* any post-sign-in mutation can slip past an uninstalled
    /// push hook. Call once at app launch.
    func bind(to auth: AuthStateManager) {
        guard stateSubscription == nil else { return }
        stateSubscription = auth.$state.sink { [weak self, weak auth] state in
            guard let self, let auth else { return }
            self.handle(state: state, auth: auth)
        }
    }

    /// React to an auth-gate transition. Only `.signedIn` runs the cloud sync;
    /// `.localOnly` (DEBUG) and `.signedOut` keep the app fully offline.
    func handle(state: AuthGateState, auth: AuthStateManager) {
        switch state {
        case .signedIn(let user):
            guard activeUserId != user.id else { return }
            start(userId: user.id, tokenProvider: auth.makeTokenProvider())
        case .signedOut, .localOnly, .checking:
            stop()
        }
    }

    func onForeground() {
        guard let coordinator else { return }
        Task { await coordinator.onForeground() }
    }

    #if DEBUG
    /// Latest sync error / pending flag, for the in-process E2E check.
    func diagnostics() async -> (error: String?, pending: Bool)? {
        await coordinator?.diagnostics()
    }
    #endif

    private func start(userId: String, tokenProvider: TokenProviding) {
        let client = SupabaseDataClient(tokenProvider: tokenProvider)
        let coordinator = CloudSyncCoordinator(
            client: client,
            database: database,
            userId: userId,
            onStatusChange: { [weak self] status in
                // Hop back to the main actor; the coordinator itself is background.
                Task { @MainActor in self?.syncStatus = status }
            }
        )
        self.coordinator = coordinator
        self.activeUserId = userId
        isPreparingSession = true
        syncStatus = .idle
        Task {
            await coordinator.start()   // pulls cloud truth, then arms push-on-change
            isPreparingSession = false
        }
    }

    private func stop() {
        isPreparingSession = false
        syncStatus = .idle
        guard let coordinator else { return }
        self.coordinator = nil
        self.activeUserId = nil
        Task { await coordinator.stop() }
    }
}
