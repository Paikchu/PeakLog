-- ============================================================
-- Durable task queue for server-side plan generation (Issue #135).
--
-- WHY A QUEUE AND NOT A BIGGER LOOP
-- The hourly cron used to do everything inside ONE HTTP request: read every
-- profile with a single unpaginated `select`, then `await generateForUser`
-- for each due user in sequence, then run the behavioral-inference sweep on
-- top. Two independent ceilings made that structurally unable to scale:
--
--   1. PostgREST caps every response at max_rows = 1000
--      (backend/supabase/config.toml:18). Profile #1001 was not "slow to be
--      picked up" -- it was *invisible*, permanently, with no error raised
--      anywhere. The sweep looked healthy while silently serving a prefix of
--      the user base.
--   2. A Supabase Edge Function request has a 150s idle timeout, while ONE
--      user's generation can legitimately burn far more: up to 3 validation
--      repair attempts x up to 2 LLM calls (generateWithRetry) x a 60s
--      per-call timeout (_shared/llm.mjs). A single slow user therefore ate
--      the whole request budget, and every user after them in the array was
--      simply never executed. Nothing recorded that they had been skipped,
--      so the next tick had no idea it was resuming anything -- there was no
--      durable cursor, no per-user retry, and no fairness: the same tail of
--      the array starved every week.
--
-- Making the loop concurrent (Promise.all) would have been the wrong fix and
-- is explicitly ruled out by the issue: it converts "the tail starves" into
-- "everyone times out together plus we DDoS the LLM provider", and it still
-- leaves progress bound to the lifetime of one HTTP request.
--
-- The fix separates DECLARING work from DOING work:
--   * cron -> `action:'enqueue'`: pages through profiles (keyset-paginated,
--     well under max_rows), writes one row per due user into this table, and
--     returns. No LLM calls, so it always finishes inside the request budget;
--     if the profile table ever grows past what one tick can scan, the
--     durable cursor below lets the next tick resume where it stopped.
--   * cron -> `action:'work'`: claims a SMALL, bounded number of tasks
--     (default 1) under a lease, processes them, reports back, returns. The
--     number of users no longer affects any single request's duration --
--     only how many worker ticks are needed to drain the queue.
--
-- Progress is now durable in Postgres instead of in an Edge Function's call
-- stack, which is what makes independent retry, backoff, fairness and
-- observability possible at all.
--
-- NOT DEPLOYED BY THIS MIGRATION ALONE: creating the queue changes nothing
-- on its own. The cron jobs are switched over in
-- 20260729102000_switch_generation_cron_to_queue.sql, kept separate on the
-- same principle as 20260708000013 vs 20260708000015 -- "enabling
-- infrastructure and turning on traffic are separate, independently
-- revertible steps".
-- ============================================================

-- ============================================================
-- 1. plan_generation_queue
--
-- One row = one unit of work for one user. `kind` distinguishes the two
-- server-side generation paths that used to share the cron sweep:
--   'weekly'    -> install NEXT week's plan (install_generated_plan)
--   'inference' -> behavioral-inference mid-week replan (replan_plan_days)
--
-- `target_date` is deliberately one column for both kinds rather than two
-- nullable ones, because it plays the same role in each: the calendar date
-- that makes this task unique and that pins WHICH instant the task was
-- declared for.
--   kind='weekly'    -> the plan's week_start_date (the target Monday)
--   kind='inference' -> the user's LOCAL calendar day the sweep observed
-- Pinning it (rather than letting the worker re-derive "next Monday" from
-- its own clock) is what makes a delayed retry safe: a task enqueued at
-- Sunday 23:50 that is not claimed until Monday 00:10 must still target the
-- week it was declared for, not the week after. The worker compares the
-- pinned date against the user's current local calendar and marks the task
-- stale rather than acting on a week it no longer belongs to.
--
-- IDEMPOTENCY KEY: (kind, user_id, target_date) is UNIQUE, so no amount of
-- re-enqueueing -- overlapping cron ticks, a retried enqueue, the four
-- hourly ticks of the same Sunday evening window -- can ever produce two
-- tasks that would both install a plan for the same user and week. Enqueue
-- writes with ON CONFLICT DO NOTHING, so a task that already exists in ANY
-- state (pending / running / succeeded / failed) is left exactly as it is.
-- In particular a 'succeeded' row is a tombstone that suppresses re-entry
-- for that week, and a 'failed' row stays failed instead of being silently
-- resurrected by the next tick -- terminal failure must be visible in the
-- metrics below and dealt with, not retried forever in a loop nobody sees.
-- ============================================================
CREATE TABLE plan_generation_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind varchar(16) NOT NULL CHECK (kind IN ('weekly', 'inference')),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  target_date date NOT NULL,
  status varchar(16) NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'running', 'succeeded', 'failed')),

  -- attempt_count is incremented at CLAIM time, not at failure time: a
  -- worker that is killed mid-generation (Edge Function timeout, deploy,
  -- OOM) never gets to report anything, and an attempt counter that only
  -- moved on reported failures would let such a task be re-claimed forever.
  attempt_count int NOT NULL DEFAULT 0,
  max_attempts int NOT NULL DEFAULT 3 CHECK (max_attempts >= 1),

  -- Scheduling gate for both the first run and every retry. Defaulting to
  -- now() means a freshly enqueued task is immediately claimable; a failed
  -- task gets pushed out by plan_generation_retry_delay().
  next_retry_at timestamptz NOT NULL DEFAULT now(),

  -- Lease / fencing token. locked_by is written at claim time and checked on
  -- every completion report, so a zombie worker whose lease already expired
  -- (and whose task was therefore reclaimed and handed to someone else)
  -- cannot come back to life and overwrite the new owner's result.
  locked_by text,
  lease_expires_at timestamptz,

  last_error text,
  result jsonb,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT plan_generation_queue_identity UNIQUE (kind, user_id, target_date)
);

COMMENT ON TABLE plan_generation_queue IS
  'Durable work queue for generate-weekly-plan (Issue #135). cron enqueues, workers claim a bounded batch under a lease. service_role only -- no end user ever reads or writes this table.';
COMMENT ON COLUMN plan_generation_queue.target_date IS
  'kind=weekly: the target week_start_date (Monday). kind=inference: the user local calendar day the sweep observed. Pinned at enqueue time so a delayed retry cannot drift onto a different week/day.';
COMMENT ON COLUMN plan_generation_queue.attempt_count IS
  'Incremented when the task is CLAIMED, so a worker that dies without reporting still burns an attempt and cannot be re-claimed indefinitely.';
COMMENT ON COLUMN plan_generation_queue.locked_by IS
  'Fencing token. complete/fail/release only apply when the caller still holds this exact lease.';

-- Hot path for claiming: "oldest due pending task first". Partial on
-- status='pending' so the index stays small no matter how many succeeded
-- tombstones accumulate -- those are the overwhelming majority of rows over
-- time and never participate in a claim.
CREATE INDEX idx_plan_generation_queue_claimable
  ON plan_generation_queue (next_retry_at, created_at)
  WHERE status = 'pending';

-- Lease reclamation scans only running rows, which are at most (number of
-- concurrent workers) at any instant.
CREATE INDEX idx_plan_generation_queue_leases
  ON plan_generation_queue (lease_expires_at)
  WHERE status = 'running';

-- Ops/debug: "what happened to this user recently".
CREATE INDEX idx_plan_generation_queue_user
  ON plan_generation_queue (user_id, created_at DESC);

CREATE TRIGGER plan_generation_queue_updated_at
  BEFORE UPDATE ON plan_generation_queue
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- RLS: this table is INFRASTRUCTURE, not user data. Unlike plan_generations
-- (which grants the owner SELECT so the app can show generation provenance),
-- there is nothing here a client should ever see or act on: lease tokens and
-- worker ids are internal, and a client that could INSERT here could make
-- the backend burn LLM budget on demand for an arbitrary user_id.
--
-- Belt and braces, because either one alone is weaker than it looks:
--   * ENABLE ROW LEVEL SECURITY with ZERO policies => deny-all for anon and
--     authenticated (RLS is default-deny; the absence of policies here is
--     the intent, not an oversight -- same reasoning recorded on
--     plan_generations for its missing INSERT/UPDATE policies).
--   * REVOKE the table grants as well, so PostgREST answers with a hard
--     permission error instead of a cheerful empty array, and so a future
--     migration that adds a policy by mistake still cannot open it up.
-- service_role bypasses RLS by design and is the only intended accessor.
ALTER TABLE plan_generation_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE plan_generation_queue FROM PUBLIC;
REVOKE ALL ON TABLE plan_generation_queue FROM anon;
REVOKE ALL ON TABLE plan_generation_queue FROM authenticated;
GRANT ALL ON TABLE plan_generation_queue TO service_role;

-- ============================================================
-- 2. plan_generation_enqueue_cursor -- durable scan position
--
-- Enqueue itself is bounded by the same 150s request budget as everything
-- else. It is far cheaper than generation (no LLM calls; a page of profiles
-- plus one batched existing-plan lookup), so a full scan is expected to
-- finish in a single tick for any realistic profile count -- but "expected
-- to" is exactly the assumption that produced this issue in the first place.
-- The cursor makes the scan RESUMABLE instead: a tick that runs out of
-- budget mid-scan persists the last profile id it processed, and the next
-- tick continues from there rather than restarting at the beginning and
-- starving the tail all over again.
--
-- Keyset pagination on profiles.id (`WHERE id > cursor ORDER BY id`) rather
-- than OFFSET: profile ids are immutable, so the position stays valid across
-- ticks and across concurrent inserts, and it never degrades into scanning
-- and discarding the pages already handled. Profiles created mid-cycle with
-- an id below the cursor are picked up on the next cycle -- acceptable
-- because the weekly window is four hours wide and enqueue is idempotent.
--
-- Single row, enforced by the CHECK on the primary key: this is one global
-- scan position, and a second row would silently mean two half-scans.
-- ============================================================
CREATE TABLE plan_generation_enqueue_cursor (
  id text PRIMARY KEY DEFAULT 'singleton' CHECK (id = 'singleton'),
  last_user_id uuid,
  cycle_started_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE plan_generation_enqueue_cursor IS
  'Single-row durable cursor for the paginated enqueue scan over profiles. last_user_id NULL = no scan in progress, start from the beginning.';

INSERT INTO plan_generation_enqueue_cursor (id) VALUES ('singleton')
  ON CONFLICT (id) DO NOTHING;

ALTER TABLE plan_generation_enqueue_cursor ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE plan_generation_enqueue_cursor FROM PUBLIC;
REVOKE ALL ON TABLE plan_generation_enqueue_cursor FROM anon;
REVOKE ALL ON TABLE plan_generation_enqueue_cursor FROM authenticated;
GRANT ALL ON TABLE plan_generation_enqueue_cursor TO service_role;

-- ============================================================
-- 3. Retry backoff
--
-- Exponential in the attempt number, capped at 30 minutes: attempt 1 -> 60s,
-- 2 -> 120s, 3 -> 240s, ... The cap matters because the weekly window is
-- only four hours wide -- an uncapped exponential would push a late retry
-- past the point where the target week is still in the future, at which
-- point install_generated_plan's C21 guard would refuse the write anyway.
--
-- Deliberately deterministic (no jitter). Jitter exists to de-synchronize
-- large fleets of retrying clients; here the concurrency ceiling is the
-- number of worker cron entries (a handful), and FOR UPDATE SKIP LOCKED
-- already prevents two workers from colliding on a row. A deterministic
-- delay is worth more: it is exactly reproducible in
-- backend/tests/planGenerationQueue.test.mjs, where retryDelaySeconds()
-- mirrors this formula and is asserted against these same constants.
-- ============================================================
CREATE OR REPLACE FUNCTION public.plan_generation_retry_delay(p_attempt int)
RETURNS interval
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT make_interval(secs => least(60 * power(2, greatest(coalesce(p_attempt, 1), 1) - 1), 1800));
$$;

COMMENT ON FUNCTION public.plan_generation_retry_delay(int) IS
  'Exponential retry backoff for plan_generation_queue: 60s * 2^(attempt-1), capped at 1800s. Mirrored by retryDelaySeconds() in _shared/planGenerationQueue.mjs.';

-- ============================================================
-- 4. Lease reclamation
--
-- The failure mode this exists for: a worker claims a task, the Edge
-- Function is killed mid-generation (150s idle timeout, a deploy, a
-- provider hang), and nobody ever reports back. Without reclamation that
-- task sits in 'running' forever and that user silently never gets a plan --
-- the exact class of invisible starvation this whole migration is about.
--
-- Reclamation does NOT reset attempt_count: the attempt was genuinely spent
-- (an LLM call was very likely paid for), so a task that keeps timing out
-- walks its way to 'failed' instead of looping forever. It goes back to
-- 'pending' with the normal backoff, or straight to 'failed' once the
-- attempts are exhausted.
--
-- FOR UPDATE SKIP LOCKED so that several workers calling this concurrently
-- (every worker calls it before claiming) never block one another; whoever
-- gets the row first reclaims it and the others simply see fewer rows.
-- ============================================================
CREATE OR REPLACE FUNCTION public.reclaim_expired_plan_generation_leases()
RETURNS int
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_count int;
BEGIN
  WITH expired AS (
    SELECT q.id, q.locked_by
    FROM plan_generation_queue q
    WHERE q.status = 'running'
      AND q.lease_expires_at IS NOT NULL
      AND q.lease_expires_at < now()
    FOR UPDATE SKIP LOCKED
  )
  UPDATE plan_generation_queue t
  SET status = CASE WHEN t.attempt_count >= t.max_attempts THEN 'failed' ELSE 'pending' END,
      next_retry_at = now() + public.plan_generation_retry_delay(t.attempt_count),
      locked_by = NULL,
      lease_expires_at = NULL,
      last_error = format('lease expired without a report from worker %s', coalesce(e.locked_by, '<unknown>'))
  FROM expired e
  WHERE t.id = e.id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

COMMENT ON FUNCTION public.reclaim_expired_plan_generation_leases() IS
  'Returns tasks whose lease expired without a report to pending (or failed once attempts are exhausted). Called by claim_plan_generation_tasks; also safe to call standalone from ops.';

-- ============================================================
-- 5. Claim
--
-- THE reason claiming is a SQL function and not a client-side
-- read-modify-write: two workers fire from cron on the same minute, both
-- read the same "oldest pending" row, both write status='running', and both
-- generate a plan for the same user -- duplicated LLM spend, and a race on
-- install_generated_plan. `FOR UPDATE SKIP LOCKED` makes that structurally
-- impossible: the second worker cannot even see a row the first has locked,
-- so it transparently moves on to the next one. This is also why the
-- concurrency knob is "how many worker cron entries exist" rather than any
-- code change -- adding workers is safe by construction.
--
-- p_limit is clamped to a small ceiling on purpose. The whole point of the
-- fix is that a request handles a BOUNDED amount of work; letting a caller
-- pass p_limit => 5000 would rebuild the original bug on top of the queue.
--
-- The lease must outlive the longest possible request (150s idle timeout)
-- or a still-running task would be reclaimed underneath its live owner and
-- executed twice; 300s default leaves a wide margin. The fencing check in
-- complete/fail below is what keeps even that case safe.
-- ============================================================
CREATE OR REPLACE FUNCTION public.claim_plan_generation_tasks(
  p_worker_id text,
  p_limit int DEFAULT 1,
  p_lease_seconds int DEFAULT 300
)
RETURNS SETOF plan_generation_queue
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_limit int := least(greatest(coalesce(p_limit, 1), 1), 10);
  v_lease_seconds int := least(greatest(coalesce(p_lease_seconds, 300), 30), 900);
BEGIN
  -- Same service_role gate as install_generated_plan / replan_plan_days.
  -- The REVOKEs at the bottom of this file are the primary defense; this is
  -- the defense in depth that survives a future migration getting its
  -- grants wrong (see the SECURITY NOTE in 20260708000013).
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'claim_plan_generation_tasks may only be called by service_role'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_worker_id IS NULL OR btrim(p_worker_id) = '' THEN
    RAISE EXCEPTION 'p_worker_id is required -- it is the fencing token for this lease'
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  -- Recover anything abandoned before looking for work, so a crashed
  -- worker's task becomes claimable on the very next tick instead of
  -- waiting for a separate janitor to run.
  PERFORM public.reclaim_expired_plan_generation_leases();

  RETURN QUERY
  WITH claimable AS (
    SELECT q.id
    FROM plan_generation_queue q
    WHERE q.status = 'pending'
      AND q.next_retry_at <= now()
    -- Oldest due first, then oldest created: FIFO fairness. This is the
    -- property that was missing before -- position in an in-memory array
    -- decided who got served, so the same tail starved every week.
    ORDER BY q.next_retry_at, q.created_at
    LIMIT v_limit
    FOR UPDATE SKIP LOCKED
  )
  UPDATE plan_generation_queue t
  SET status = 'running',
      attempt_count = t.attempt_count + 1,
      locked_by = p_worker_id,
      lease_expires_at = now() + make_interval(secs => v_lease_seconds),
      last_error = NULL
  FROM claimable c
  WHERE t.id = c.id
  RETURNING t.*;
END $$;

COMMENT ON FUNCTION public.claim_plan_generation_tasks(text, int, int) IS
  'Atomically claims up to p_limit (clamped 1..10) due tasks under a lease using FOR UPDATE SKIP LOCKED. service_role only.';

-- ============================================================
-- 6. Completion reports
--
-- All three take p_worker_id and match it against locked_by. Without that
-- fence the following is reachable: worker A stalls past its lease, the task
-- is reclaimed and re-claimed by worker B, then A finally wakes up and
-- reports -- clobbering B's state and, worse, potentially marking succeeded
-- a task B is still working on. Every one of these returns a boolean so the
-- caller can log the "my lease was already gone" case instead of assuming
-- its report landed.
-- ============================================================
CREATE OR REPLACE FUNCTION public.complete_plan_generation_task(
  p_task_id uuid,
  p_worker_id text,
  p_result jsonb DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_count int;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'complete_plan_generation_task may only be called by service_role'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE plan_generation_queue
  SET status = 'succeeded',
      locked_by = NULL,
      lease_expires_at = NULL,
      last_error = NULL,
      result = p_result
  WHERE id = p_task_id
    AND status = 'running'
    AND locked_by = p_worker_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END $$;

CREATE OR REPLACE FUNCTION public.fail_plan_generation_task(
  p_task_id uuid,
  p_worker_id text,
  p_error text,
  p_retryable boolean DEFAULT true
)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_count int;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'fail_plan_generation_task may only be called by service_role'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE plan_generation_queue t
  -- p_retryable=false is for errors where another attempt provably cannot
  -- help (an unknown user, a target week that is already in the past). Those
  -- go terminal immediately rather than burning two more LLM budgets to
  -- reach the same conclusion.
  SET status = CASE
        WHEN p_retryable IS NOT TRUE THEN 'failed'
        WHEN t.attempt_count >= t.max_attempts THEN 'failed'
        ELSE 'pending'
      END,
      next_retry_at = now() + public.plan_generation_retry_delay(t.attempt_count),
      locked_by = NULL,
      lease_expires_at = NULL,
      -- Bounded: last_error is diagnostic, and an LLM validation failure can
      -- carry a very long violation list. Truncating keeps one pathological
      -- task from bloating the table the metrics view has to scan.
      last_error = left(coalesce(p_error, 'unspecified error'), 2000)
  WHERE t.id = p_task_id
    AND t.status = 'running'
    AND t.locked_by = p_worker_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END $$;

-- Give back a task that was claimed but never started -- the worker ran out
-- of request budget before reaching it. Distinct from fail(): no attempt was
-- actually spent, so attempt_count is given back and the task is immediately
-- due again rather than pushed out by the backoff. Without this, a worker
-- claiming a batch of 2 that only has time for 1 would silently consume an
-- attempt from the untouched task on every single tick.
CREATE OR REPLACE FUNCTION public.release_plan_generation_task(
  p_task_id uuid,
  p_worker_id text
)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_count int;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'release_plan_generation_task may only be called by service_role'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE plan_generation_queue t
  SET status = 'pending',
      attempt_count = greatest(t.attempt_count - 1, 0),
      next_retry_at = now(),
      locked_by = NULL,
      lease_expires_at = NULL
  WHERE t.id = p_task_id
    AND t.status = 'running'
    AND t.locked_by = p_worker_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END $$;

-- ============================================================
-- 7. Metrics + backlog alerting (Issue #135 acceptance criterion 4)
--
-- The old design had nothing to observe: work existed only inside a running
-- request, so "did every due user get a plan?" could only be answered by
-- diffing training_plans against profiles after the fact. With the queue,
-- every unit of work is a durable row, so status counts and queue lag are
-- just aggregates.
--
-- The view is security_invoker so it does NOT become an RLS bypass: a view
-- created by the migration role would otherwise run with that role's rights
-- (Supabase's security_definer_view advisor flags exactly this), which would
-- hand any grantee a readable window onto a deny-all table. With invoker
-- semantics the underlying RLS applies normally, and only service_role --
-- which bypasses RLS by design -- can read anything.
-- ============================================================
CREATE OR REPLACE VIEW public.plan_generation_queue_metrics
WITH (security_invoker = true) AS
SELECT
  q.kind,
  q.status,
  count(*)::bigint AS task_count,
  min(q.created_at) AS oldest_created_at,
  max(q.updated_at) AS newest_updated_at,
  max(q.attempt_count) AS max_attempt_count,
  -- Queue lag: how long the oldest task in this bucket has been due but not
  -- yet acted on. Meaningful for the 'pending' bucket (that IS the backlog
  -- signal); for terminal buckets it just reports the age of the oldest row.
  greatest(extract(epoch FROM (now() - min(q.next_retry_at)))::bigint, 0) AS oldest_due_lag_seconds
FROM plan_generation_queue q
GROUP BY q.kind, q.status;

COMMENT ON VIEW public.plan_generation_queue_metrics IS
  'Per (kind, status) task counts plus the oldest due-but-unstarted lag. security_invoker so the underlying deny-all RLS still applies.';

-- Single-call health probe for whatever ends up polling it (uptime check,
-- dashboard, manual ops). Returns one jsonb object rather than a rowset so a
-- caller can alert on `->>'alert'` without understanding the schema.
--
-- p_lag_alert_seconds default 900: the weekly window is four hours wide and
-- workers tick every minute, so a task still unstarted 15 minutes after it
-- became due means workers are down, wedged, or hopelessly under-provisioned
-- -- all of which need a human before the window closes.
CREATE OR REPLACE FUNCTION public.plan_generation_queue_health(
  p_lag_alert_seconds int DEFAULT 900
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_pending bigint;
  v_running bigint;
  v_succeeded bigint;
  v_failed bigint;
  v_failed_recent bigint;
  v_oldest_pending_age bigint;
  v_oldest_pending_lag bigint;
  v_expired_leases bigint;
  v_reasons text[] := ARRAY[]::text[];
BEGIN
  SELECT
    count(*) FILTER (WHERE status = 'pending'),
    count(*) FILTER (WHERE status = 'running'),
    count(*) FILTER (WHERE status = 'succeeded'),
    count(*) FILTER (WHERE status = 'failed'),
    count(*) FILTER (WHERE status = 'failed' AND updated_at > now() - interval '24 hours'),
    coalesce(max(extract(epoch FROM (now() - created_at))::bigint)
             FILTER (WHERE status = 'pending'), 0),
    greatest(coalesce(max(extract(epoch FROM (now() - next_retry_at))::bigint)
             FILTER (WHERE status = 'pending'), 0), 0),
    count(*) FILTER (WHERE status = 'running' AND lease_expires_at < now())
  INTO v_pending, v_running, v_succeeded, v_failed, v_failed_recent,
       v_oldest_pending_age, v_oldest_pending_lag, v_expired_leases
  FROM plan_generation_queue;

  IF v_oldest_pending_lag > p_lag_alert_seconds THEN
    v_reasons := v_reasons || format('oldest pending task is %s s past due (threshold %s s)',
                                     v_oldest_pending_lag, p_lag_alert_seconds);
  END IF;
  IF v_expired_leases > 0 THEN
    v_reasons := v_reasons || format('%s task(s) hold an expired lease -- workers are dying mid-run', v_expired_leases);
  END IF;
  IF v_failed_recent > 0 THEN
    v_reasons := v_reasons || format('%s task(s) exhausted their attempts in the last 24h', v_failed_recent);
  END IF;

  RETURN jsonb_build_object(
    'pending', v_pending,
    'running', v_running,
    'succeeded', v_succeeded,
    'failed', v_failed,
    'failed_last_24h', v_failed_recent,
    'oldest_pending_age_seconds', v_oldest_pending_age,
    'oldest_pending_due_lag_seconds', v_oldest_pending_lag,
    'expired_leases', v_expired_leases,
    'lag_alert_threshold_seconds', p_lag_alert_seconds,
    'alert', array_length(v_reasons, 1) IS NOT NULL,
    'alert_reasons', to_jsonb(v_reasons),
    'observed_at', now()
  );
END $$;

COMMENT ON FUNCTION public.plan_generation_queue_health(int) IS
  'One-call queue health: pending/running/succeeded/failed counts, oldest-pending lag, expired leases, and an alert flag with human-readable reasons.';

-- Retention. Terminal rows are pure history once their week has passed, and
-- kind='inference' writes one row per user per day, so the table would grow
-- without bound and slowly weigh down the metrics aggregates. 30 days keeps
-- roughly four weekly cycles of forensic history.
--
-- Deleting a 'failed' row also makes that (kind, user_id, target_date)
-- enqueueable again -- irrelevant in practice because the target date is
-- long past by then, and the worker's staleness check would no-op it.
CREATE OR REPLACE FUNCTION public.purge_plan_generation_queue(
  p_retain interval DEFAULT interval '30 days'
)
RETURNS int
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_count int;
BEGIN
  DELETE FROM plan_generation_queue
  WHERE status IN ('succeeded', 'failed')
    AND updated_at < now() - p_retain;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

COMMENT ON FUNCTION public.purge_plan_generation_queue(interval) IS
  'Deletes terminal (succeeded/failed) queue rows older than p_retain. Scheduled daily in 20260729102000_switch_generation_cron_to_queue.sql.';

-- ============================================================
-- 8. Permission lockdown
--
-- Mandatory, per the SECURITY NOTE in
-- 20260708000013_phase2_generation_rpc_and_scheduling_extensions.sql: new
-- functions in this project's public schema pick up an EXECUTE grant for
-- `anon` by default, and `REVOKE ALL ... FROM PUBLIC` alone does NOT remove
-- it. Without these lines claim_plan_generation_tasks would be reachable as
-- an unauthenticated POST /rpc/claim_plan_generation_tasks -- letting anyone
-- lease away every queued task and starve the whole pipeline, which is the
-- very failure this migration exists to eliminate.
-- ============================================================
REVOKE ALL ON FUNCTION public.plan_generation_retry_delay(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.plan_generation_retry_delay(int) FROM anon;
REVOKE ALL ON FUNCTION public.plan_generation_retry_delay(int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.plan_generation_retry_delay(int) TO service_role;

REVOKE ALL ON FUNCTION public.reclaim_expired_plan_generation_leases() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reclaim_expired_plan_generation_leases() FROM anon;
REVOKE ALL ON FUNCTION public.reclaim_expired_plan_generation_leases() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.reclaim_expired_plan_generation_leases() TO service_role;

REVOKE ALL ON FUNCTION public.claim_plan_generation_tasks(text, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_plan_generation_tasks(text, int, int) FROM anon;
REVOKE ALL ON FUNCTION public.claim_plan_generation_tasks(text, int, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.claim_plan_generation_tasks(text, int, int) TO service_role;

REVOKE ALL ON FUNCTION public.complete_plan_generation_task(uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.complete_plan_generation_task(uuid, text, jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.complete_plan_generation_task(uuid, text, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.complete_plan_generation_task(uuid, text, jsonb) TO service_role;

REVOKE ALL ON FUNCTION public.fail_plan_generation_task(uuid, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fail_plan_generation_task(uuid, text, text, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.fail_plan_generation_task(uuid, text, text, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fail_plan_generation_task(uuid, text, text, boolean) TO service_role;

REVOKE ALL ON FUNCTION public.release_plan_generation_task(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.release_plan_generation_task(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.release_plan_generation_task(uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.release_plan_generation_task(uuid, text) TO service_role;

REVOKE ALL ON FUNCTION public.plan_generation_queue_health(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.plan_generation_queue_health(int) FROM anon;
REVOKE ALL ON FUNCTION public.plan_generation_queue_health(int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.plan_generation_queue_health(int) TO service_role;

REVOKE ALL ON FUNCTION public.purge_plan_generation_queue(interval) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_plan_generation_queue(interval) FROM anon;
REVOKE ALL ON FUNCTION public.purge_plan_generation_queue(interval) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.purge_plan_generation_queue(interval) TO service_role;

REVOKE ALL ON public.plan_generation_queue_metrics FROM PUBLIC;
REVOKE ALL ON public.plan_generation_queue_metrics FROM anon;
REVOKE ALL ON public.plan_generation_queue_metrics FROM authenticated;
GRANT SELECT ON public.plan_generation_queue_metrics TO service_role;
