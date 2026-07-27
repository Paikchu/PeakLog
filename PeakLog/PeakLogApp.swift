import SwiftUI
import Combine

@main
struct PeakLogApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var localizationManager = LocalizationManager()
    @StateObject private var authManager: AuthStateManager
    @StateObject private var syncController: CloudSyncController

    init() {
        let factory = SupabaseClientFactory()
        let provider = SupabaseAuthProvider(client: factory.makeAuthClient())
        let apiClient = factory.makeAPIClient {
            try await provider.validToken()
        }
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
