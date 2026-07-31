-- ============================================================
-- Issue #148, retention half: schedule the record_deletions sweep.
--
-- Deliberately a SEPARATE migration from 20260731090000 (which creates the
-- table, the trigger and the purge function), on the principle recorded in
-- 20260708000015_phase2_schedule_generation_cron.sql: "enabling infrastructure
-- and turning on traffic are separate, independently revertible steps".
--
-- Here that separation is load-bearing rather than ceremonial. The first
-- migration is purely additive — a new table, triggers that write to it, a
-- function nobody calls. THIS file is the one that starts *deleting*
-- tombstones, i.e. the one that starts making devices unable to learn about old
-- deletions. Rolling the retention policy back (or changing the window) is then
-- `select cron.unschedule('record-deletions-purge')` plus a new migration,
-- with no effect on the deletion protocol itself.
--
-- ROLLBACK: `select cron.unschedule('record-deletions-purge');`. Nothing else
-- depends on the job existing; without it the table simply grows, which is
-- inert until it is large enough to matter.
-- ============================================================

-- Guarded because cron.unschedule() raises if the job does not exist, and this
-- migration must stay re-runnable against a branch database or a fresh
-- `supabase db reset` where cron state may differ.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'record-deletions-purge') THEN
    PERFORM cron.unschedule('record-deletions-purge');
  END IF;
END $$;

-- Daily, off-peak, and deliberately not on the same minute as
-- 'plan-generation-queue-purge' (04:17) — two sweeps holding delete locks on
-- unrelated tables at the same instant is harmless but makes a slow-query
-- report ambiguous.
SELECT cron.schedule(
  'record-deletions-purge',
  '43 4 * * *',
  $$ select public.purge_record_deletions(); $$
);
