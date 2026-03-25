import Foundation

@main
struct SupabaseConfigTestRunner {
    static func main() {
        prefersDebugOverridesWhenPresent()
        fallsBackToDefaultValuesWhenOverridesAreMissing()
        print("supabase_config_test passed")
    }

    private static func prefersDebugOverridesWhenPresent() {
        let environment = [
            "PEAKLOG_DEBUG_SUPABASE_URL": "http://127.0.0.1:54321",
            "PEAKLOG_DEBUG_SUPABASE_ANON_KEY": "local-anon-key"
        ]

        let resolvedURL = SupabaseConfig.resolveURL(
            environment: environment,
            fallback: URL(string: "https://example.supabase.co")!
        )
        let resolvedKey = SupabaseConfig.resolveAnonKey(
            environment: environment,
            fallback: "prod-anon-key"
        )

        precondition(
            resolvedURL.absoluteString == "http://127.0.0.1:54321",
            "Expected debug URL override to take precedence"
        )
        precondition(
            resolvedKey == "local-anon-key",
            "Expected debug anon key override to take precedence"
        )
    }

    private static func fallsBackToDefaultValuesWhenOverridesAreMissing() {
        let environment: [String: String] = [:]

        let resolvedURL = SupabaseConfig.resolveURL(
            environment: environment,
            fallback: URL(string: "https://example.supabase.co")!
        )
        let resolvedKey = SupabaseConfig.resolveAnonKey(
            environment: environment,
            fallback: "prod-anon-key"
        )

        precondition(
            resolvedURL.absoluteString == "https://example.supabase.co",
            "Expected fallback URL when no debug override is present"
        )
        precondition(
            resolvedKey == "prod-anon-key",
            "Expected fallback anon key when no debug override is present"
        )
    }
}
