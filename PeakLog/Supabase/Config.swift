import Foundation

/// Supabase project credentials.
enum SupabaseConfig {
    private static let productionURL = URL(string: "https://dejoqutbflrrscgsvbog.supabase.co")!
    private static let productionAnonKey = "sb_publishable_tmqt9aob-xUcYb9K1NOSCg_qeQBiLWO"

    /// Production Supabase project URL, with DEBUG-only local override support.
    static let url = resolveURL(
        environment: ProcessInfo.processInfo.environment,
        fallback: productionURL
    )

    /// Production publishable key, with DEBUG-only local override support.
    static let anonKey = resolveAnonKey(
        environment: ProcessInfo.processInfo.environment,
        fallback: productionAnonKey
    )

    static func resolveURL(environment: [String: String], fallback: URL) -> URL {
        #if DEBUG
        if let raw = environment["PEAKLOG_DEBUG_SUPABASE_URL"], let url = URL(string: raw) {
            return url
        }
        #endif
        return fallback
    }

    static func resolveAnonKey(environment: [String: String], fallback: String) -> String {
        #if DEBUG
        if let value = environment["PEAKLOG_DEBUG_SUPABASE_ANON_KEY"], !value.isEmpty {
            return value
        }
        #endif
        return fallback
    }
}
