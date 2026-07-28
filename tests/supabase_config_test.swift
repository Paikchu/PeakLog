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
            "PEAKLOG_DEBUG_SUPABASE_PUBLISHABLE_KEY": "local-publishable-key"
        ]

        let resolvedURL = SupabaseConfig.resolveURL(
            environment: environment,
            fallback: URL(string: "https://example.supabase.co")!
        )
        let resolvedKey = SupabaseConfig.resolvePublishableKey(
            environment: environment,
            fallback: "prod-publishable-key"
        )

        precondition(
            resolvedURL.absoluteString == "http://127.0.0.1:54321",
            "Expected debug URL override to take precedence"
        )
        precondition(
            resolvedKey == "local-publishable-key",
            "Expected debug publishable key override to take precedence"
        )
    }

    private static func fallsBackToDefaultValuesWhenOverridesAreMissing() {
        let environment: [String: String] = [:]

        let resolvedURL = SupabaseConfig.resolveURL(
            environment: environment,
            fallback: URL(string: "https://example.supabase.co")!
        )
        let resolvedKey = SupabaseConfig.resolvePublishableKey(
            environment: environment,
            fallback: "prod-publishable-key"
        )

        precondition(
            resolvedURL.absoluteString == "https://example.supabase.co",
            "Expected fallback URL when no debug override is present"
        )
        precondition(
            resolvedKey == "prod-publishable-key",
            "Expected fallback publishable key when no debug override is present"
        )
    }
}
