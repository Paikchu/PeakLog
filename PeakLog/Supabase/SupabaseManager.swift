import Foundation
import Supabase

/// Singleton Supabase client. Access via `SupabaseManager.shared.client`.
final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey,
            options: SupabaseClientOptions(
                auth: .init(
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }
}
