-- ============================================================
-- Issue #135, traffic half: point pg_cron at the queue instead of at the
-- all-users-in-one-request sweep.
--
-- Deliberately a SEPARATE migration from 20260729101500 (which only creates
-- the queue), on the same principle recorded in
-- 20260708000015_phase2_schedule_generation_cron.sql: "enabling
-- infrastructure and turning on traffic are separate, independently
-- revertible steps". Creating the queue is inert; THIS file is the one that
-- changes what runs in production, and it must not be applied until the new
-- generate-weekly-plan revision (the one that understands `action`) is
-- deployed. Applying it against the old function would post an unknown
-- `action` field to a handler that ignores it -- i.e. the old whole-fleet
-- sweep, four times an hour instead of once.
--
-- ROLLBACK, in this order:
--   1. `select cron.unschedule(...)` the six jobs below and re-create
--      'generate-weekly-plan-hourly' exactly as it appears in 20260708000015.
--   2. Redeploy the PREVIOUS generate-weekly-plan revision. Step 1 alone does
--      NOT restore the old behaviour: the new revision treats the old job's
--      `{}` body as `action:'enqueue'` (deliberately -- that is what makes the
--      forward deployment order safe), so the restored hourly job would keep
--      enqueueing into a queue no worker is draining.
-- The queue table is intentionally left in place when rolling back -- its
-- 'succeeded' rows are the record of who already has a plan this week, and
-- dropping them would let the restored sweep regenerate for users who were
-- already served (install_generated_plan would reject the duplicate week
-- with a unique_violation, so the damage is wasted LLM spend and noisy
-- failures rather than corrupted plans, but there is no reason to invite it).
-- ============================================================

-- The old job. Guarded because cron.unschedule() raises if the job does not
-- exist, and this migration must stay re-runnable against a branch database
-- or a fresh `supabase db reset` where cron state may differ.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'generate-weekly-plan-hourly') THEN
    PERFORM cron.unschedule('generate-weekly-plan-hourly');
  END IF;
END $$;

-- Also drop any of this migration's own jobs before recreating them, so a
-- re-run replaces rather than duplicates (cron.schedule() upserts by name in
-- recent pg_cron, but not in every version this project might run against).
DO $$
DECLARE
  v_name text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'generate-weekly-plan-enqueue',
    'plan-generation-queue-worker-1',
    'plan-generation-queue-worker-2',
    'plan-generation-queue-worker-3',
    'plan-generation-queue-worker-4',
    'plan-generation-queue-purge'
  ] LOOP
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_name) THEN
      PERFORM cron.unschedule(v_name);
    END IF;
  END LOOP;
END $$;

-- ============================================================
-- Enqueue: every 15 minutes.
--
-- The window predicates themselves are still hour-granular
-- (isGenerationWindowOpen = local Sunday >= 20:00), so hourly would be
-- sufficient to CATCH every user. Running 4x more often is about the durable
-- cursor rather than about detection: if a scan ever runs out of request
-- budget partway through the profile table, this is how quickly it gets to
-- resume from where it stopped. Enqueue makes no LLM calls -- a page of
-- profiles plus one batched existing-plan lookup -- so the extra ticks are
-- nearly free, and re-enqueueing an already-queued user is a no-op thanks to
-- the (kind, user_id, target_date) unique key.
-- ============================================================
SELECT cron.schedule(
  'generate-weekly-plan-enqueue',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := 'https://fqyurmsuvtdafbnynurg.supabase.co/functions/v1/generate-weekly-plan',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', 'sb_publishable_7UeChilW6B8aPscPF9huzg_tXniKGal',
      'x-generation-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'generation_secret')
    ),
    body := '{"action":"enqueue"}'::jsonb
  ) as request_id;
  $$
);

-- ============================================================
-- Workers: four independent entries, every minute, each claiming at most 2
-- tasks.
--
-- WHY FOUR ENTRIES AND NOT ONE WITH limit=8
-- Throughput here is (concurrent requests) x (tasks per request), and only
-- the first factor is free. Tasks inside one request run SEQUENTIALLY on
-- purpose -- that is the whole point of the fix, a request must never take
-- longer than its own bounded budget -- so raising `limit` past what fits in
-- ~110s just means the extra tasks get released back to pending untouched.
-- Concurrency has to come from more requests, and pg_cron gives that by
-- simply scheduling the same call several times: FOR UPDATE SKIP LOCKED
-- guarantees the four workers never collide on a row, so this is safe by
-- construction and needs no code change to scale. Add or remove entries here
-- to move the ceiling.
--
-- Current ceiling: 4 requests/min x 2 tasks = up to 480 users/hour, against a
-- four-hour-wide weekly window (local Sunday 20:00-23:59) -- comfortably more
-- than the 1000-profile ceiling that made this a bug in the first place, with
-- room left before DeepSeek concurrency becomes the binding constraint.
--
-- net.http_post is fire-and-forget (pg_net queues the request and returns),
-- so a slow worker never blocks the cron scheduler or the next tick.
-- ============================================================
DO $$
DECLARE
  v_worker int;
BEGIN
  FOR v_worker IN 1..4 LOOP
    PERFORM cron.schedule(
      format('plan-generation-queue-worker-%s', v_worker),
      '* * * * *',
      $job$
      select net.http_post(
        url := 'https://fqyurmsuvtdafbnynurg.supabase.co/functions/v1/generate-weekly-plan',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'apikey', 'sb_publishable_7UeChilW6B8aPscPF9huzg_tXniKGal',
          'x-generation-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'generation_secret')
        ),
        body := '{"action":"work","limit":2}'::jsonb
      ) as request_id;
      $job$
    );
  END LOOP;
END $$;

-- ============================================================
-- Retention. kind='inference' enqueues one row per user per day, so without
-- this the queue grows monotonically forever and every metrics aggregate
-- slowly gets more expensive. Off-peak hour, and the function only touches
-- terminal rows older than 30 days.
-- ============================================================
SELECT cron.schedule(
  'plan-generation-queue-purge',
  '17 4 * * *',
  $$ select public.purge_plan_generation_queue(); $$
);
