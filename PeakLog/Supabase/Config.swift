import Foundation

/// Supabase project credentials.
/// After running `supabase start`, copy the values from `supabase status` here.
enum SupabaseConfig {
    /// Local dev:  http://127.0.0.1:54321
    /// Production: https://<project-ref>.supabase.co
    static let url = URL(string: "http://127.0.0.1:54321")!

    /// Local dev:  copy "anon key" from `supabase status`
    /// Production: copy from Supabase dashboard → Project Settings → API
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
}
