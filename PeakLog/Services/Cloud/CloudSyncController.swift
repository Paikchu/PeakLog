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
    private var activeTokenProvider: TokenProviding?
    private var stateSubscription: AnyCancellable?

    /// True while a one-tap replan request is in flight — the Today UI disables
    /// the adjust menu so a double-tap can't fire two requests.
    @Published private(set) var isRequestingReplan = false

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
        Task {
            // Reconcile first: if the device's timezone changed (e.g. travel),
            // this mutation must land before onForeground() decides whether
            // there's anything pending to push, or it waits for next time.
            await reconcileDeviceTimezone()
            await coordinator.onForeground()
        }
    }

    /// Writes the device's real IANA timezone to preferences if it differs
    /// from what's on record. `profiles.timezone` defaults to `'UTC'`
    /// server-side and the client has otherwise never set it — left alone,
    /// server-side timezone-sensitive logic (e.g. Phase 2's Sunday-evening
    /// weekly plan generation) would silently run against the wrong clock
    /// for every user. No UI: this is a background reconciliation, same as
    /// the sync itself.
    private func reconcileDeviceTimezone() async {
        let deviceTimezone = TimeZone.current.identifier
        let profile = await database.fetchProfile()
        guard profile.preferences.timezone != deviceTimezone else { return }
        _ = try? await database.updatePreferences(UpdatePreferencesRequest(
            notificationsEnabled: nil,
            weightUnit: nil,
            timezone: deviceTimezone,
            language: nil
        ))
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
        self.activeTokenProvider = tokenProvider
        isPreparingSession = true
        syncStatus = .idle
        Task {
            let started = await coordinator.start()
            guard started else {
                isPreparingSession = false
                return
            }
            await reconcileDeviceTimezone()   // hook is armed by now, so this pushes
            isPreparingSession = false
        }
    }

    private func stop() {
        isPreparingSession = false
        syncStatus = .idle
        activeTokenProvider = nil
        guard let coordinator else { return }
        self.coordinator = nil
        self.activeUserId = nil
        Task { await coordinator.stop() }
    }

    /// Whether one-tap replan is available at all — false in DEBUG local mode
    /// and while signed out (no cloud session), so the UI can hide the control.
    var isReplanAvailable: Bool {
        coordinator != nil && activeUserId != nil && activeTokenProvider != nil
    }

    /// Fires a one-tap replan (Phase 3). Records nothing itself — the caller has
    /// already recorded the local signal event — then calls the Edge Function
    /// and, on a real replan, pulls so the new plan lands in the local cache and
    /// the UI refreshes. Returns nil when there's no active cloud session.
    func requestReplan(signal: ReplanSignal) async -> PlanReplanService.Outcome? {
        guard let coordinator, let userId = activeUserId, let tokenProvider = activeTokenProvider else {
            return nil
        }
        guard !isRequestingReplan else { return nil }
        isRequestingReplan = true
        defer { isRequestingReplan = false }

        let service = PlanReplanService(tokenProvider: tokenProvider)
        do {
            let outcome = try await service.requestReplan(userId: userId, signal: signal)
            if case .replanned = outcome {
                // Pull the server-applied replan into the local cache. Because
                // this immediately follows a successful call, the revision guard
                // on the next push is naturally satisfied.
                await coordinator.pull()
            }
            return outcome
        } catch {
            return .failed(reason: "\(error)")
        }
    }
}
