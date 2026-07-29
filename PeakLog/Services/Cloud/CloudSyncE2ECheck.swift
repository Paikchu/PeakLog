#if DEBUG
import Foundation

/// In-process end-to-end check for the cloud sync glue that UI automation can't
/// easily reach (the simulator keyboard is unusable for the login form). Runs
/// only when launched with `PEAKLOG_E2E=1` and the dev credentials in
/// `PEAKLOG_DEV_EMAIL` / `PEAKLOG_DEV_PASSWORD`. Drives the *real* objects —
/// `AuthStateManager`, `CloudSyncController`, the coordinator, `AppServices`,
/// `LocalAppDatabase` — then reads the row back from the cloud to prove the
/// onChange → push path fired. Prints `PEAKLOG_E2E:` lines to stdout.
@MainActor
enum CloudSyncE2ECheck {
    static func runIfRequested(auth: AuthStateManager, sync: CloudSyncController) async {
        let env = ProcessInfo.processInfo.environment
        guard env["PEAKLOG_E2E"] == "1" else { return }
        guard let email = env["PEAKLOG_DEV_EMAIL"], let password = env["PEAKLOG_DEV_PASSWORD"] else {
            log("SKIP missing PEAKLOG_DEV_EMAIL/PASSWORD")
            return
        }

        // 1. Sign in. The app's onChange(of: auth.state) starts the coordinator.
        await auth.signIn(email: email, password: password)
        guard case let .signedIn(user) = auth.state else {
            log("FAIL sign-in: \(auth.errorMessage ?? "unknown")")
            return
        }
        log("signed in \(user.id)")

        // 2. Wait for the initial pull (gate) to finish.
        await waitUntil { !sync.isPreparingSession }
        log("initial pull done")

        // 3. Real mutation through the real service → LocalAppDatabase → onChange → push.
        let marker = 41 + Int.random(in: 1...58)  // distinctive duration to find the row
        do {
            _ = try await AppServices.workoutService.createRunningRecord(
                workoutDate: Date(), durationMinutes: marker, distanceKm: 6.66, source: .manual
            )
        } catch {
            log("FAIL mutation: \(error)")
            return
        }
        log("created running record dur=\(marker)")

        // 4. Read back from the cloud with an independent client.
        guard let client = sync.makeE2EDataClient(tokenProvider: auth.makeTokenProvider()) else {
            log("FAIL API client unavailable")
            return
        }
        var found = false
        for attempt in 1...30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let rows = (try? await client.fetch(RunningWorkoutRow.self, table: "running_workouts", query: [])) ?? []
            if rows.contains(where: { $0.duration_minutes == marker }) {
                log("PASS row present in cloud after \(attempt) checks")
                found = true
                break
            }
        }
        if !found {
            let diag = await sync.diagnostics()
            log("FAIL row never appeared in cloud — sync diagnostics: error=\(diag?.error ?? "nil") pending=\(diag?.pending.description ?? "nil")")
        }

        // 5. Clean up so the dev account is left empty. Expressed as a plain
        // list-then-delete rather than a prune: a prune only destroys rows it
        // has observed, which is the point of the prune, whereas "wipe the dev
        // account" genuinely does mean "delete whatever is there".
        if let listed = try? await client.listIds(table: "running_workouts") {
            try? await client.deleteIds(table: "running_workouts", ids: listed.elements)
        }
        log("done")
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<40 where !condition() {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private static func log(_ message: String) {
        // stderr is unbuffered, so lines survive even when the app is killed
        // mid-run under `simctl launch --console`.
        FileHandle.standardError.write(Data("PEAKLOG_E2E: \(message)\n".utf8))
    }
}
#endif
