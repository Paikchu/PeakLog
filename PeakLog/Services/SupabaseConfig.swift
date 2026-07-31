import Foundation

/// Resolves the Supabase endpoint the app talks to.
///
/// Three layers, highest priority first:
///
/// 1. **Environment overrides** (`PEAKLOG_DEBUG_SUPABASE_*`) — point a local
///    run at a `supabase start` stack without rebuilding.
/// 2. **Build-time injection** — the app's Info.plist carries
///    `PeakLogSupabaseURL` / `PeakLogSupabasePublishableKey`, declared in
///    `Config/PeakLog-Info.plist` and fed from the `PEAKLOG_SUPABASE_URL` /
///    `PEAKLOG_SUPABASE_PUBLISHABLE_KEY` build settings (an xcconfig, or
///    `xcodebuild PEAKLOG_SUPABASE_URL=…`). Both are optional: unset expands to
///    an empty string and falls through to layer 3, so an existing build needs
///    no change at all. This is the rotation seam — changing the project's
///    endpoint no longer requires editing Swift.
/// 3. **Compiled-in production defaults** — the last resort, so the app still
///    ships working values with nothing configured.
///
/// The publishable key is deliberately *not* treated as a secret: it is meant
/// to be readable in a client binary and row access is enforced by RLS. The
/// point of injecting it is rotation, not concealment — hence a plain build
/// setting rather than a Keychain or a fetch at launch.
///
/// Resolution is a pure function of its inputs so it stays testable without a
/// live environment (see `tests/supabase_config_test.swift`).
nonisolated struct SupabaseConfig: Sendable {
    let url: URL
    let publishableKey: String

    // Environment override keys, honored in DEBUG-style local runs.
    static let urlOverrideKey = "PEAKLOG_DEBUG_SUPABASE_URL"
    static let publishableKeyOverrideKey = "PEAKLOG_DEBUG_SUPABASE_PUBLISHABLE_KEY"

    // Info.plist keys carrying the build-time injection.
    static let urlInfoPlistKey = "PeakLogSupabaseURL"
    static let publishableKeyInfoPlistKey = "PeakLogSupabasePublishableKey"

    // Production defaults (project `fqyurmsuvtdafbnynurg`).
    static let productionURLString = "https://fqyurmsuvtdafbnynurg.supabase.co"
    static let productionPublishableKey = "sb_publishable_7UeChilW6B8aPscPF9huzg_tXniKGal"

    /// The configuration for the current process, or `nil` when not one of the
    /// three layers yields a parsable URL. Callers surface that as
    /// `AppAuthError.notConfigured` rather than force-unwrapping into a crash:
    /// with the URL now injectable, a malformed value is a build-configuration
    /// mistake someone can actually make, not just a typo in this file.
    static var current: SupabaseConfig? {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            infoDictionary: Bundle.main.infoDictionary ?? [:]
        )
    }

    static func resolve(
        environment: [String: String],
        infoDictionary: [String: Any]
    ) -> SupabaseConfig? {
        guard let url = resolveURL(
            environment: environment,
            infoDictionary: infoDictionary,
            fallback: endpointURL(from: productionURLString)
        ) else { return nil }

        return SupabaseConfig(
            url: url,
            publishableKey: resolvePublishableKey(
                environment: environment,
                infoDictionary: infoDictionary,
                fallback: productionPublishableKey
            )
        )
    }

    /// Each candidate that isn't a usable endpoint falls through to the next,
    /// so a broken injected value degrades to the compiled-in default instead
    /// of taking the app down.
    static func resolveURL(
        environment: [String: String],
        infoDictionary: [String: Any] = [:],
        fallback: URL?
    ) -> URL? {
        let candidates = [
            trimmed(environment[urlOverrideKey]),
            trimmed(infoDictionary[urlInfoPlistKey] as? String)
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let url = endpointURL(from: candidate) { return url }
        }
        return fallback
    }

    /// `URL(string:)` alone is a near-useless validator — "not a url at all"
    /// parses happily as a relative URL — so a candidate has to actually look
    /// like a Supabase endpoint. Without this, a typo'd build setting wouldn't
    /// crash; it would quietly send every request nowhere, which is worse.
    static func endpointURL(from raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    static func resolvePublishableKey(
        environment: [String: String],
        infoDictionary: [String: Any] = [:],
        fallback: String
    ) -> String {
        trimmed(environment[publishableKeyOverrideKey])
            ?? trimmed(infoDictionary[publishableKeyInfoPlistKey] as? String)
            ?? fallback
    }

    /// An unset build setting expands to an empty string in the generated
    /// Info.plist, so empty must read as "absent", not as "configured to
    /// nothing".
    private static func trimmed(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}
