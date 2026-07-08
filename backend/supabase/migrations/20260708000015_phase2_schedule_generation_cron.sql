-- Phase 2: wire the hourly pg_cron trigger for generate-weekly-plan.
-- See docs/plans/2026-07-08-phase2-weekly-generation-plan.md §3.4/§3.5 and
-- §7 step 6 ("enabling infrastructure and turning on traffic are separate,
-- independently-revertible steps" -- this migration is the "turn on
-- traffic" half, applied only after the Edge Function was deployed and
-- live-verified via dry_run + a real install for the dev account).
--
-- Fires every hour. The function itself decides per-user whether their
-- local Sunday 20:00 window is currently open (selectDueUsers /
-- isGenerationWindowOpen in index.ts), so an hourly cadence is sufficient
-- to catch every user's local Sunday evening across all timezones without
-- needing a per-timezone schedule. Off-window invocations are cheap no-ops
-- (verified live: a call during a Wednesday returned zero results with no
-- LLM calls or writes).
--
-- The apikey below is the project's publishable key (safe to embed --
-- it's the public client key, not a secret). Actual authorization is the
-- x-generation-secret header, read fresh from Vault on every run so the
-- secret value never has to be duplicated into a migration file.
-- Applied to fqyurmsuvtdafbnynurg on 2026-07-08 via MCP.
select cron.schedule(
  'generate-weekly-plan-hourly',
  '0 * * * *',
  $$
  select net.http_post(
    url := 'https://fqyurmsuvtdafbnynurg.supabase.co/functions/v1/generate-weekly-plan',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', 'sb_publishable_7UeChilW6B8aPscPF9huzg_tXniKGal',
      'x-generation-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'generation_secret')
    ),
    body := '{}'::jsonb
  ) as request_id;
  $$
);
