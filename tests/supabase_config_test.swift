import Foundation

// Logic test: the three-layer Supabase endpoint resolution (env override →
// build-time Info.plist injection → compiled-in production default). Compile
// with the resolver alone:
//   swiftc -parse-as-library PeakLog/Services/SupabaseConfig.swift \
//     tests/supabase_config_test.swift -o /tmp/sc && /tmp/sc

@main
struct SupabaseConfigTestRunner {
    static func main() {
        prefersDebugOverridesWhenPresent()
        fallsBackToDefaultValuesWhenOverridesAreMissing()
        usesBuildTimeInjectionWhenNoEnvironmentOverride()
        environmentOverrideBeatsBuildTimeInjection()
        treatsUnsetBuildSettingAsAbsent()
        fallsBackWhenInjectedURLIsUnparsable()
        resolvesToNilWhenNoLayerYieldsAURL()
        resolveAppliesEveryLayer()
        print("supabase_config_test passed")
    }

    private static func prefersDebugOverridesWhenPresent() {
        let environment = [
            "PEAKLOG_DEBUG_SUPABASE_URL": "http://127.0.0.1:54321",
            "PEAKLOG_DEBUG_SUPABASE_PUBLISHABLE_KEY": "local-publishable-key"
        ]

        let resolvedURL = SupabaseConfig.resolveURL(
            environment: environment,
            fallback: URL(string: "https://example.supabase.co")
        )
        let resolvedKey = SupabaseConfig.resolvePublishableKey(
            environment: environment,
            fallback: "prod-publishable-key"
        )

        precondition(
            resolvedURL?.absoluteString == "http://127.0.0.1:54321",
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
            fallback: URL(string: "https://example.supabase.co")
        )
        let resolvedKey = SupabaseConfig.resolvePublishableKey(
            environment: environment,
            fallback: "prod-publishable-key"
        )

        precondition(
            resolvedURL?.absoluteString == "https://example.supabase.co",
            "Expected fallback URL when no debug override is present"
        )
        precondition(
            resolvedKey == "prod-publishable-key",
            "Expected fallback publishable key when no debug override is present"
        )
    }

    // MARK: - Build-time injection (Issue #32)

    private static func usesBuildTimeInjectionWhenNoEnvironmentOverride() {
        let infoDictionary: [String: Any] = [
            "PeakLogSupabaseURL": "https://rotated.supabase.co",
            "PeakLogSupabasePublishableKey": "sb_publishable_rotated"
        ]

        let resolvedURL = SupabaseConfig.resolveURL(
            environment: [:],
            infoDictionary: infoDictionary,
            fallback: URL(string: "https://example.supabase.co")
        )
        let resolvedKey = SupabaseConfig.resolvePublishableKey(
            environment: [:],
            infoDictionary: infoDictionary,
            fallback: "prod-publishable-key"
        )

        precondition(
            resolvedURL?.absoluteString == "https://rotated.supabase.co",
            "Expected the injected URL to win over the compiled-in default"
        )
        precondition(
            resolvedKey == "sb_publishable_rotated",
            "Expected the injected key to win over the compiled-in default"
        )
    }

    private static func environmentOverrideBeatsBuildTimeInjection() {
        let environment = [
            "PEAKLOG_DEBUG_SUPABASE_URL": "http://127.0.0.1:54321",
            "PEAKLOG_DEBUG_SUPABASE_PUBLISHABLE_KEY": "local-publishable-key"
        ]
        let infoDictionary: [String: Any] = [
            "PeakLogSupabaseURL": "https://rotated.supabase.co",
            "PeakLogSupabasePublishableKey": "sb_publishable_rotated"
        ]

        let resolvedURL = SupabaseConfig.resolveURL(
            environment: environment,
            infoDictionary: infoDictionary,
            fallback: URL(string: "https://example.supabase.co")
        )
        let resolvedKey = SupabaseConfig.resolvePublishableKey(
            environment: environment,
            infoDictionary: infoDictionary,
            fallback: "prod-publishable-key"
        )

        precondition(
            resolvedURL?.absoluteString == "http://127.0.0.1:54321",
            "Expected a local run to still be able to override an injected build"
        )
        precondition(
            resolvedKey == "local-publishable-key",
            "Expected a local run to still be able to override an injected build"
        )
    }

    /// An unset build setting expands to an empty string in the generated
    /// Info.plist. That must read as "not configured" — otherwise every build
    /// that doesn't opt in would resolve to an empty endpoint. This is what
    /// keeps CI building unchanged.
    private static func treatsUnsetBuildSettingAsAbsent() {
        let infoDictionary: [String: Any] = [
            "PeakLogSupabaseURL": "",
            "PeakLogSupabasePublishableKey": "   "
        ]

        let resolvedURL = SupabaseConfig.resolveURL(
            environment: [:],
            infoDictionary: infoDictionary,
            fallback: URL(string: "https://example.supabase.co")
        )
        let resolvedKey = SupabaseConfig.resolvePublishableKey(
            environment: [:],
            infoDictionary: infoDictionary,
            fallback: "prod-publishable-key"
        )

        precondition(
            resolvedURL?.absoluteString == "https://example.supabase.co",
            "Expected an empty injected URL to fall through to the default"
        )
        precondition(
            resolvedKey == "prod-publishable-key",
            "Expected a blank injected key to fall through to the default"
        )
    }

    private static func fallsBackWhenInjectedURLIsUnparsable() {
        let resolvedURL = SupabaseConfig.resolveURL(
            environment: ["PEAKLOG_DEBUG_SUPABASE_URL": "not a url at all"],
            infoDictionary: ["PeakLogSupabaseURL": "also not a url"],
            fallback: URL(string: "https://example.supabase.co")
        )

        precondition(
            resolvedURL?.absoluteString == "https://example.supabase.co",
            "Expected an unparsable candidate to degrade to the default, not to trap"
        )
    }

    /// The branch that used to be `URL(string: …)!`.
    private static func resolvesToNilWhenNoLayerYieldsAURL() {
        let resolvedURL = SupabaseConfig.resolveURL(
            environment: [:],
            infoDictionary: [:],
            fallback: nil
        )

        precondition(
            resolvedURL == nil,
            "Expected nil — the caller turns this into .notConfigured instead of crashing"
        )
    }

    private static func resolveAppliesEveryLayer() {
        let compiledIn = SupabaseConfig.resolve(environment: [:], infoDictionary: [:])
        precondition(
            compiledIn?.url.absoluteString == SupabaseConfig.productionURLString,
            "Expected a bare process to resolve to the compiled-in production URL"
        )
        precondition(
            compiledIn?.publishableKey == SupabaseConfig.productionPublishableKey,
            "Expected a bare process to resolve to the compiled-in production key"
        )

        let injected = SupabaseConfig.resolve(
            environment: [:],
            infoDictionary: [
                "PeakLogSupabaseURL": "https://rotated.supabase.co",
                "PeakLogSupabasePublishableKey": "sb_publishable_rotated"
            ]
        )
        precondition(
            injected?.url.absoluteString == "https://rotated.supabase.co",
            "Expected resolve() to honor build-time injection"
        )
        precondition(
            injected?.publishableKey == "sb_publishable_rotated",
            "Expected resolve() to honor build-time injection"
        )
    }
}
