type EnvMap = Record<string, string | undefined>;

export function getSupabaseUserClientKey(env: EnvMap): string | undefined {
  return env.SUPABASE_ANON_KEY ?? env.SUPABASE_PUBLISHABLE_KEY;
}

export function getSupabaseAdminClientKey(env: EnvMap): string | undefined {
  return env.SUPABASE_SERVICE_ROLE_KEY ?? env.SUPABASE_SECRET_KEY;
}
