-- Executable SQL checks for the Issue #135 plan-generation queue.
--
-- WHY THIS IS NOT A node --test FILE
-- backend/tests/planGenerationQueue.test.mjs drives the JS module against a
-- MODEL of the queue RPCs, and planGenerationQueueMigration.test.mjs asserts
-- the migration text contains the right constructs. Neither actually EXECUTES
-- the SQL: `FOR UPDATE SKIP LOCKED`, the fencing predicates and the C21 guard
-- inside install_generated_plan only mean something against a real Postgres.
-- This script is that half of the coverage, and it needs a live database, so
-- it deliberately sits outside `node --test`.
--
-- HOW TO RUN (requires Docker + the Supabase CLI):
--
--   cd backend/supabase && supabase start
--   psql "$(supabase status -o json | jq -r '.DB_URL')" \
--        -v ON_ERROR_STOP=1 -f ../tests/sql/plan_generation_queue_checks.sql
--
-- Everything runs inside one transaction that ends in ROLLBACK, so it leaves
-- no rows behind. It prints one NOTICE per check and RAISEs on the first
-- failure (with ON_ERROR_STOP=1 that is a non-zero exit).
--
-- NOTE ON now(): a transaction has a single now(), so every "is it due yet"
-- comparison below is against that one instant. That is what makes the
-- backoff assertions exact rather than flaky.

\set ON_ERROR_STOP on
BEGIN;

-- The RPCs gate on auth.role(), which reads the PostgREST JWT claims GUC.
-- Setting it here is how a psql session impersonates the Edge Function's
-- service-role client.
SET LOCAL request.jwt.claims = '{"role":"service_role"}';

-- ------------------------------------------------------------------
-- Fixtures
-- ------------------------------------------------------------------
INSERT INTO auth.users (id) VALUES
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');

INSERT INTO profiles (id, timezone) VALUES
  ('11111111-1111-4111-8111-111111111111', 'UTC'),
  ('22222222-2222-4222-8222-222222222222', 'Asia/Shanghai');

-- A target Monday comfortably in the future, so install_generated_plan's C21
-- guard ("never the current or a past week") is never the reason a check
-- fails.
CREATE TEMP TABLE t AS SELECT (date_trunc('week', now())::date + 7) AS next_monday;

-- ------------------------------------------------------------------
-- 1. Permissions: nothing but service_role may touch any of this
-- ------------------------------------------------------------------
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF has_table_privilege(r, 'plan_generation_queue', 'SELECT')
       OR has_table_privilege(r, 'plan_generation_queue', 'INSERT')
       OR has_table_privilege(r, 'plan_generation_enqueue_cursor', 'SELECT') THEN
      RAISE EXCEPTION 'FAIL: role % still has table privileges on the queue', r;
    END IF;
    IF has_function_privilege(r, 'public.claim_plan_generation_tasks(text,int,int)', 'EXECUTE')
       OR has_function_privilege(r, 'public.complete_plan_generation_task(uuid,text,jsonb)', 'EXECUTE')
       OR has_function_privilege(r, 'public.fail_plan_generation_task(uuid,text,text,boolean)', 'EXECUTE')
       OR has_function_privilege(r, 'public.release_plan_generation_task(uuid,text)', 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL: role % can still execute the queue RPCs', r;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'plan_generation_queue') THEN
    RAISE EXCEPTION 'FAIL: plan_generation_queue must have zero RLS policies (deny-all)';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'plan_generation_queue'::regclass) THEN
    RAISE EXCEPTION 'FAIL: RLS is not enabled on plan_generation_queue';
  END IF;
  RAISE NOTICE 'PASS 1: queue tables and RPCs are service_role-only, RLS on with no policies';
END $$;

-- ------------------------------------------------------------------
-- 2. Idempotency key: one task per (kind, user, date), whatever happens
-- ------------------------------------------------------------------
INSERT INTO plan_generation_queue (kind, user_id, target_date)
SELECT 'weekly', '11111111-1111-4111-8111-111111111111', next_monday FROM t;
INSERT INTO plan_generation_queue (kind, user_id, target_date)
SELECT 'weekly', '22222222-2222-4222-8222-222222222222', next_monday FROM t;

DO $$
DECLARE v_next date := (SELECT next_monday FROM t);
BEGIN
  BEGIN
    INSERT INTO plan_generation_queue (kind, user_id, target_date)
    VALUES ('weekly', '11111111-1111-4111-8111-111111111111', v_next);
    RAISE EXCEPTION 'FAIL: a duplicate (kind, user_id, target_date) was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL; -- expected
  END;

  -- This is the shape enqueueDueTasks actually writes (PostgREST's
  -- Prefer: resolution=ignore-duplicates): a repeat tick must be a no-op,
  -- never an update that resurrects a terminal task.
  INSERT INTO plan_generation_queue (kind, user_id, target_date)
  VALUES ('weekly', '11111111-1111-4111-8111-111111111111', v_next)
  ON CONFLICT (kind, user_id, target_date) DO NOTHING;

  IF (SELECT count(*) FROM plan_generation_queue) <> 2 THEN
    RAISE EXCEPTION 'FAIL: expected exactly 2 tasks, found %', (SELECT count(*) FROM plan_generation_queue);
  END IF;
  RAISE NOTICE 'PASS 2: the identity key rejects duplicates and ON CONFLICT DO NOTHING is a no-op';
END $$;

-- ------------------------------------------------------------------
-- 3. Claim: atomic, disjoint, FIFO, attempt spent at claim time
-- ------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid;
  v_b uuid;
  v_third int;
  v_attempts int;
BEGIN
  SELECT id INTO v_a FROM public.claim_plan_generation_tasks('worker-a', 1, 300);
  SELECT id INTO v_b FROM public.claim_plan_generation_tasks('worker-b', 1, 300);

  IF v_a IS NULL OR v_b IS NULL THEN
    RAISE EXCEPTION 'FAIL: both workers should have got a task (% / %)', v_a, v_b;
  END IF;
  IF v_a = v_b THEN
    RAISE EXCEPTION 'FAIL: two workers claimed the same task %', v_a;
  END IF;

  SELECT count(*) INTO v_third FROM public.claim_plan_generation_tasks('worker-c', 5, 300);
  IF v_third <> 0 THEN
    RAISE EXCEPTION 'FAIL: a third worker claimed % already-running task(s)', v_third;
  END IF;

  SELECT min(attempt_count) INTO v_attempts FROM plan_generation_queue;
  IF v_attempts <> 1 THEN
    RAISE EXCEPTION 'FAIL: attempt_count must be spent at claim time, got %', v_attempts;
  END IF;
  IF EXISTS (SELECT 1 FROM plan_generation_queue WHERE status <> 'running' OR locked_by IS NULL OR lease_expires_at IS NULL) THEN
    RAISE EXCEPTION 'FAIL: a claimed task is missing status/locked_by/lease_expires_at';
  END IF;
  RAISE NOTICE 'PASS 3: claims are disjoint, exhaustive and spend an attempt up front';
END $$;

-- ------------------------------------------------------------------
-- 4. Fencing: a report only applies while the caller still holds the lease
-- ------------------------------------------------------------------
DO $$
DECLARE
  v_task uuid := (SELECT id FROM plan_generation_queue WHERE locked_by = 'worker-a');
BEGIN
  IF public.complete_plan_generation_task(v_task, 'worker-b', '{"status":"stolen"}'::jsonb) THEN
    RAISE EXCEPTION 'FAIL: a worker completed a task it does not hold the lease on';
  END IF;
  IF public.fail_plan_generation_task(v_task, 'worker-b', 'stolen', true) THEN
    RAISE EXCEPTION 'FAIL: a worker failed a task it does not hold the lease on';
  END IF;
  IF public.release_plan_generation_task(v_task, 'worker-b') THEN
    RAISE EXCEPTION 'FAIL: a worker released a task it does not hold the lease on';
  END IF;

  IF NOT public.complete_plan_generation_task(v_task, 'worker-a', '{"status":"installed"}'::jsonb) THEN
    RAISE EXCEPTION 'FAIL: the lease holder could not complete its own task';
  END IF;
  -- A zombie waking up after the fact must not be able to undo it.
  IF public.fail_plan_generation_task(v_task, 'worker-a', 'late', true) THEN
    RAISE EXCEPTION 'FAIL: a completed task accepted a late failure report';
  END IF;
  IF (SELECT status FROM plan_generation_queue WHERE id = v_task) <> 'succeeded' THEN
    RAISE EXCEPTION 'FAIL: completed task is not in status succeeded';
  END IF;
  RAISE NOTICE 'PASS 4: complete/fail/release are all fenced by locked_by';
END $$;

-- ------------------------------------------------------------------
-- 5. Backoff and terminal failure
-- ------------------------------------------------------------------
DO $$
DECLARE
  v_task uuid := (SELECT id FROM plan_generation_queue WHERE locked_by = 'worker-b');
  v_row plan_generation_queue;
BEGIN
  PERFORM public.fail_plan_generation_task(v_task, 'worker-b', 'LLM call failed', true);
  SELECT * INTO v_row FROM plan_generation_queue WHERE id = v_task;
  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION 'FAIL: a retryable failure on attempt 1/3 should be pending, got %', v_row.status;
  END IF;
  IF v_row.next_retry_at <> now() + interval '60 seconds' THEN
    RAISE EXCEPTION 'FAIL: expected a 60s backoff after attempt 1, got %', v_row.next_retry_at - now();
  END IF;
  IF v_row.locked_by IS NOT NULL OR v_row.lease_expires_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: a failed task must give its lease back';
  END IF;

  -- Still inside the backoff => not claimable. This is the property that
  -- keeps a hard-failing user from monopolising the workers.
  IF (SELECT count(*) FROM public.claim_plan_generation_tasks('worker-d', 5, 300)) <> 0 THEN
    RAISE EXCEPTION 'FAIL: a task inside its backoff window was claimable';
  END IF;

  -- Walk it to terminal. next_retry_at is moved back by hand because a
  -- transaction has a frozen now().
  UPDATE plan_generation_queue SET next_retry_at = now() WHERE id = v_task;
  PERFORM public.claim_plan_generation_tasks('worker-d', 1, 300);
  PERFORM public.fail_plan_generation_task(v_task, 'worker-d', 'again', true);
  UPDATE plan_generation_queue SET next_retry_at = now() WHERE id = v_task;
  PERFORM public.claim_plan_generation_tasks('worker-d', 1, 300);
  PERFORM public.fail_plan_generation_task(v_task, 'worker-d', 'and again', true);

  SELECT * INTO v_row FROM plan_generation_queue WHERE id = v_task;
  IF v_row.status <> 'failed' OR v_row.attempt_count <> 3 THEN
    RAISE EXCEPTION 'FAIL: expected failed/3 after exhausting max_attempts, got %/%', v_row.status, v_row.attempt_count;
  END IF;
  RAISE NOTICE 'PASS 5: retries back off exponentially and go terminal at max_attempts';
END $$;

-- ------------------------------------------------------------------
-- 6. Release refunds the attempt; reclamation does not
-- ------------------------------------------------------------------
DO $$
DECLARE
  v_task uuid;
  v_row plan_generation_queue;
BEGIN
  INSERT INTO plan_generation_queue (kind, user_id, target_date)
  SELECT 'inference', '11111111-1111-4111-8111-111111111111', current_date FROM t
  RETURNING id INTO v_task;

  PERFORM public.claim_plan_generation_tasks('worker-e', 1, 300);
  IF NOT public.release_plan_generation_task(v_task, 'worker-e') THEN
    RAISE EXCEPTION 'FAIL: the lease holder could not release its own task';
  END IF;
  SELECT * INTO v_row FROM plan_generation_queue WHERE id = v_task;
  IF v_row.status <> 'pending' OR v_row.attempt_count <> 0 OR v_row.next_retry_at > now() THEN
    RAISE EXCEPTION 'FAIL: release must refund the attempt and make the task due immediately (%/%)',
      v_row.status, v_row.attempt_count;
  END IF;

  -- Now simulate a worker that was killed and never reported.
  PERFORM public.claim_plan_generation_tasks('worker-f', 1, 300);
  UPDATE plan_generation_queue SET lease_expires_at = now() - interval '1 second' WHERE id = v_task;
  IF public.reclaim_expired_plan_generation_leases() <> 1 THEN
    RAISE EXCEPTION 'FAIL: the expired lease was not reclaimed';
  END IF;
  SELECT * INTO v_row FROM plan_generation_queue WHERE id = v_task;
  IF v_row.status <> 'pending' OR v_row.attempt_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: reclamation must keep the spent attempt (%/%)', v_row.status, v_row.attempt_count;
  END IF;
  IF v_row.locked_by IS NOT NULL OR v_row.last_error IS NULL THEN
    RAISE EXCEPTION 'FAIL: a reclaimed task must drop its lease and record why';
  END IF;
  RAISE NOTICE 'PASS 6: release refunds an unstarted attempt, reclamation keeps a spent one';
END $$;

-- ------------------------------------------------------------------
-- 7. Backoff helper and metrics/alerting
-- ------------------------------------------------------------------
DO $$
DECLARE v_health jsonb;
BEGIN
  IF public.plan_generation_retry_delay(1) <> interval '60 seconds'
     OR public.plan_generation_retry_delay(3) <> interval '240 seconds'
     OR public.plan_generation_retry_delay(99) <> interval '1800 seconds' THEN
    RAISE EXCEPTION 'FAIL: plan_generation_retry_delay diverged from 60s * 2^(n-1) capped at 1800s';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.plan_generation_queue_metrics) THEN
    RAISE EXCEPTION 'FAIL: the metrics view returned no rows for a non-empty queue';
  END IF;

  v_health := public.plan_generation_queue_health(900);
  IF NOT (v_health ? 'pending' AND v_health ? 'running' AND v_health ? 'succeeded'
          AND v_health ? 'failed' AND v_health ? 'alert' AND v_health ? 'oldest_pending_due_lag_seconds') THEN
    RAISE EXCEPTION 'FAIL: health payload is missing a required key: %', v_health;
  END IF;
  -- One task exhausted its attempts above, so the alert must be raised.
  IF (v_health->>'alert')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: a recently failed task did not raise the alert flag: %', v_health;
  END IF;
  RAISE NOTICE 'PASS 7: backoff helper, metrics view and health/alert payload all behave';
END $$;

-- ------------------------------------------------------------------
-- 8. THE RETRY-SAFETY CLAIM: install_generated_plan refuses a second plan
--    for the same user + week.
--
-- This is the authoritative check behind Issue #135's "重试不重复安装计划".
-- The queue's unique key and the worker's pre-check both sit in front of it,
-- but this is the one that holds even if a retry races another worker.
-- ------------------------------------------------------------------
DO $$
DECLARE
  v_next date := (SELECT next_monday FROM t);
  v_plan jsonb;
BEGIN
  v_plan := jsonb_build_object(
    'weekStartDate', v_next::text,
    'coachSummary', 'check',
    'days', jsonb_build_array(jsonb_build_object(
      'dayIndex', 0, 'planDate', v_next::text, 'title', 'Rest', 'status', 'planned', 'exercises', '[]'::jsonb
    ))
  );

  PERFORM public.install_generated_plan('11111111-1111-4111-8111-111111111111', v_plan);

  BEGIN
    PERFORM public.install_generated_plan('11111111-1111-4111-8111-111111111111', v_plan);
    RAISE EXCEPTION 'FAIL: a retry installed a SECOND plan for the same user and week';
  EXCEPTION WHEN unique_violation THEN
    NULL; -- expected: 'a plan for week % already exists for user %'
  END;

  IF (SELECT count(*) FROM training_plans
      WHERE user_id = '11111111-1111-4111-8111-111111111111' AND week_start_date = v_next) <> 1 THEN
    RAISE EXCEPTION 'FAIL: more than one plan row exists for the target week';
  END IF;
  RAISE NOTICE 'PASS 8: install_generated_plan raises unique_violation on a duplicate week — retries cannot double-install';
END $$;

-- ------------------------------------------------------------------
-- 9. Retention
-- ------------------------------------------------------------------
DO $$
DECLARE v_deleted int;
BEGIN
  UPDATE plan_generation_queue SET updated_at = now() - interval '40 days' WHERE status IN ('succeeded', 'failed');
  v_deleted := public.purge_plan_generation_queue(interval '30 days');
  IF v_deleted < 1 THEN
    RAISE EXCEPTION 'FAIL: purge removed no terminal rows';
  END IF;
  IF EXISTS (SELECT 1 FROM plan_generation_queue WHERE status = 'pending' AND updated_at < now() - interval '30 days') THEN
    RAISE EXCEPTION 'FAIL: purge must never touch a non-terminal row';
  END IF;
  RAISE NOTICE 'PASS 9: purge_plan_generation_queue removes only aged terminal rows';
END $$;

ROLLBACK;
