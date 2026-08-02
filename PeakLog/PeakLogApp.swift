import SwiftUI
import Combine

@main
struct PeakLogApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var localizationManager = LocalizationManager()
    @StateObject private var authManager: AuthStateManager
    @StateObject private var syncController: CloudSyncController
    @StateObject private var reminderScheduler = TrainingReminderScheduler()

    init() {
        // No resolvable endpoint means the build is misconfigured; launch into
        // the login screen and report it there rather than trapping (Issue #32).
        let factory = SupabaseConfig.current.map { SupabaseClientFactory(config: $0) }
        let provider: AuthProviding = factory?.makeAuthProvider() ?? UnconfiguredAuthProvider()
        let apiClient = factory?.makeAPIClient()
        _authManager = StateObject(wrappedValue: AuthStateManager(provider: provider))
        _syncController = StateObject(
            wrappedValue: CloudSyncController(apiClient: apiClient)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(auth: authManager, sync: syncController)
                .environmentObject(themeManager)
                .environmentObject(localizationManager)
                .environmentObject(syncController)
                .environmentObject(authManager)
                .environmentObject(reminderScheduler)
                .environment(\.locale, localizationManager.locale)
                .rootAppearance(themeManager)
                .task {
                    // Subscribe before restore so the first state transition is
                    // observed and the sync lifecycle tracks auth synchronously.
                    syncController.bind(to: authManager)
                    await authManager.restore()
                    #if DEBUG
                    await CloudSyncE2ECheck.runIfRequested(auth: authManager, sync: syncController)
                    #endif
                }
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    guard newPhase == .active else { return }
                    localizationManager.refreshFromSystem()
                    // `initial: true` fires this immediately on cold launch, which can
                    // race ahead of the `.task`'s `await authManager.restore()` above.
                    // Only kick off a foreground sync tick once the auth gate has
                    // actually resolved to a signed-in session — otherwise this tick is
                    // silently dropped (CloudSyncController.onForeground() no-ops until
                    // its coordinator exists) and the first foreground reconciliation
                    // after launch is lost rather than merely deferred.
                    guard case .signedIn = authManager.state else { return }
                    syncController.onForeground()
                }
                // Training reminders can only be *pre*-scheduled — iOS runs no
                // code of ours at delivery time — so every pending request is
                // rebuilt from the current plan whenever the app crosses the
                // foreground boundary. `.background` matters as much as
                // `.active`: leaving the app right after a workout is exactly
                // when today's now-pointless reminder has to be dropped.
                // Deliberately not gated on the auth state — reminders are
                // device-local and apply in local-only mode too.
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    guard newPhase == .active || newPhase == .background else { return }
                    Task { await reminderScheduler.refresh() }
                }
                // A pull landing (`isPreparingSession` falling back to false)
                // is the other moment the plan can change under us, and on cold
                // launch it happens *after* the scene is already active — so
                // without this the first foreground schedule would be built
                // from the pre-pull cache and never revisited.
                .onChange(of: syncController.isPreparingSession) { _, isPreparing in
                    guard !isPreparing else { return }
                    Task { await reminderScheduler.refresh() }
                }
        }
    }
}

/// Switches between the login screen and the app based on the auth gate.
/// While a persisted session is being restored we hold on a splash so the
/// login screen never flashes for an already-signed-in user.
private struct RootView: View {
    @ObservedObject var auth: AuthStateManager
    @ObservedObject var sync: CloudSyncController

    var body: some View {
        switch auth.state {
        case .checking:
            SplashView()
        case .signedOut:
            AuthView(auth: auth)
        case .signedIn:
            // Hold on the splash until the first pull lands so the UI never
            // flashes stale seed/local data before cloud truth arrives.
            if sync.isPreparingSession {
                SplashView()
            } else {
                ContentView()
            }
        case .localOnly:
            ContentView()
        }
    }
}

private struct SplashView: View {
    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ProgressView()
        }
    }
}
