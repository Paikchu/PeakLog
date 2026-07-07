import Foundation

/// Resolves the Supabase endpoint the app talks to.
///
/// Production values are compiled in (a publishable key is safe to ship in a
/// client — row access is enforced by RLS). A local `supabase start` stack can
/// be targeted by exporting the debug overrides, which take precedence when
/// present. The resolver is a pure function of its inputs so it stays testable
/// without a live environment (see `tests/supabase_config_test.swift`).
nonisolated struct SupabaseConfig: Sendable {
    let url: URL
    let anonKey: String

    // Environment override keys, honored in DEBUG-style local runs.
    static let urlOverrideKey = "PEAKLOG_DEBUG_SUPABASE_URL"
    static let anonKeyOverrideKey = "PEAKLOG_DEBUG_SUPABASE_ANON_KEY"

    // Production defaults (project `fqyurmsuvtdafbnynurg`).
    static let productionURL = URL(string: "https://fqyurmsuvtdafbnynurg.supabase.co")!
    static let productionAnonKey = "sb_publishable_7UeChilW6B8aPscPF9huzg_tXniKGal"

    /// The configuration for the current process, applying any debug overrides.
    static var current: SupabaseConfig {
        let environment = ProcessInfo.processInfo.environment
        return SupabaseConfig(
            url: resolveURL(environment: environment, fallback: productionURL),
            anonKey: resolveAnonKey(environment: environment, fallback: productionAnonKey)
        )
    }

    static func resolveURL(environment: [String: String], fallback: URL) -> URL {
        guard let raw = environment[urlOverrideKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let override = URL(string: raw)
        else { return fallback }
        return override
    }

    static func resolveAnonKey(environment: [String: String], fallback: String) -> String {
        guard let raw = environment[anonKeyOverrideKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return fallback }
        return raw
    }
}
