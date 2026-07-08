-- ============================================================
-- Phase 3: mid-week replan schema + RPC.
-- See docs/plans/2026-07-08-phase3-midweek-replan-plan.md §3.1/§7 step 1.
-- ============================================================

-- provenance: distinguish weekly generation from a mid-week replan, and
-- record what triggered it (user tap vs behavioral inference) + which
-- structured signal the user picked, if any.
ALTER TABLE plan_generations
  ADD COLUMN IF NOT EXISTS kind varchar(16) NOT NULL DEFAULT 'weekly',
  ADD COLUMN IF NOT EXISTS trigger varchar(16),
  ADD COLUMN IF NOT EXISTS signal varchar(16);

ALTER TABLE plan_generations
  DROP CONSTRAINT IF EXISTS plan_generations_kind_check;
ALTER TABLE plan_generations
  ADD CONSTRAINT plan_generations_kind_check CHECK (kind IN ('weekly', 'replan'));

ALTER TABLE plan_generations
  DROP CONSTRAINT IF EXISTS plan_generations_trigger_check;
ALTER TABLE plan_generations
  ADD CONSTRAINT plan_generations_trigger_check CHECK (trigger IS NULL OR trigger IN ('user_tap', 'inference'));

ALTER TABLE plan_generations
  DROP CONSTRAINT IF EXISTS plan_generations_signal_check;
ALTER TABLE plan_generations
  ADD CONSTRAINT plan_generations_signal_check CHECK (signal IS NULL OR signal IN ('skip_today', 'low_energy', 'time_limited'));

-- optimistic-concurrency guard: the client checks this before pushing its
-- own plan-table writes (plan §4.2) so a stale client push can never
-- silently clobber a server-side replan that happened since the last pull.
ALTER TABLE training_plans
  ADD COLUMN IF NOT EXISTS revision int NOT NULL DEFAULT 0;

-- ============================================================
-- replan_plan_days: transactionally replaces one or more days of the
-- CURRENT week's active plan. SECURITY DEFINER, service_role only — same
-- anon-grant pitfall as install_generated_plan (see 20260708000013), so
-- this function is written with the explicit REVOKE + auth.role() check
-- from day one rather than discovered live a second time.
--
-- Hard safety invariant (C31, mirrors C21's philosophy for day-granularity
-- writes): every target day must independently satisfy, re-derived inside
-- this function and never trusted from the caller:
--   1. plan_date >= today (in the user's own timezone)
--   2. zero sets under that day have completed_at or linked_exercise_set_id set
-- Violating either rolls back the ENTIRE call — replan is all-or-nothing
-- across the requested days, never a partial replan that silently skips
-- the day that failed validation.
--
-- Optimistic lock: p_expected_revision must match the plan's current
-- revision (read under FOR UPDATE, so concurrent replan_plan_days calls on
-- the same plan serialize instead of racing) — a stale caller (context
-- read before someone else's replan landed) is rejected rather than
-- overwriting a newer replan.
-- ============================================================
CREATE OR REPLACE FUNCTION replan_plan_days(
  p_user_id uuid,
  p_plan_id uuid,
  p_days jsonb,
  p_expected_revision int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_timezone text;
  v_current_week_monday date;
  v_plan_week_start date;
  v_plan_status text;
  v_plan_revision int;
  v_today date;
  v_day jsonb;
  v_plan_date date;
  v_day_id uuid;
  v_exercise jsonb;
  v_exercise_id uuid;
  v_set jsonb;
  v_replanned_dates jsonb := '[]'::jsonb;
  v_new_revision int;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'replan_plan_days may only be called by service_role'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT timezone INTO v_user_timezone FROM profiles WHERE id = p_user_id;
  IF v_user_timezone IS NULL THEN
    v_user_timezone := 'UTC';
  END IF;
  v_today := (now() AT TIME ZONE v_user_timezone)::date;
  v_current_week_monday := date_trunc('week', (now() AT TIME ZONE v_user_timezone))::date;

  -- Lock the plan row for the duration of the transaction so two concurrent
  -- replan_plan_days calls on the same plan serialize rather than race.
  SELECT week_start_date, status, revision INTO v_plan_week_start, v_plan_status, v_plan_revision
  FROM training_plans WHERE id = p_plan_id AND user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'plan % not found for user %', p_plan_id, p_user_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_plan_status != 'active' THEN
    RAISE EXCEPTION 'refusing to replan a non-active plan (status=%)', v_plan_status
      USING ERRCODE = 'check_violation';
  END IF;

  -- Replan only ever targets the CURRENT week's plan. A future week belongs
  -- to weekly generation (install_generated_plan / C21); a past week is
  -- history and must never be touched by any write path.
  IF v_plan_week_start != v_current_week_monday THEN
    RAISE EXCEPTION 'refusing to replan a plan that is not the current week (plan week %, current week %)',
      v_plan_week_start, v_current_week_monday
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_plan_revision != p_expected_revision THEN
    RAISE EXCEPTION 'revision mismatch: expected %, actual % (plan changed since context was read)',
      p_expected_revision, v_plan_revision
      USING ERRCODE = 'serialization_failure';
  END IF;

  -- Validation pass (C31): check every target day BEFORE mutating any of
  -- them, so a violation on day 3 never leaves days 1-2 partially replanned.
  FOR v_day IN SELECT * FROM jsonb_array_elements(p_days)
  LOOP
    v_plan_date := (v_day->>'planDate')::date;

    IF v_plan_date < v_today THEN
      RAISE EXCEPTION 'refusing to replan a day in the past (% < today %)', v_plan_date, v_today
        USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM training_plan_days WHERE plan_id = p_plan_id AND plan_date = v_plan_date
    ) THEN
      RAISE EXCEPTION 'no existing day row for plan % date %', p_plan_id, v_plan_date
        USING ERRCODE = 'no_data_found';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM training_plan_days d
      JOIN training_plan_exercises e ON e.plan_day_id = d.id
      JOIN training_plan_sets s ON s.plan_exercise_id = e.id
      WHERE d.plan_id = p_plan_id AND d.plan_date = v_plan_date
        AND (s.completed_at IS NOT NULL OR s.linked_exercise_set_id IS NOT NULL)
    ) THEN
      RAISE EXCEPTION 'refusing to replan a day with completed sets (%)', v_plan_date
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  -- Mutation pass: for each target day, keep the day row (id stable, so no
  -- client-side dangling reference) but refresh title/focus, and replace
  -- its exercises/sets wholesale. Days NOT in p_days are never touched.
  FOR v_day IN SELECT * FROM jsonb_array_elements(p_days)
  LOOP
    v_plan_date := (v_day->>'planDate')::date;

    SELECT id INTO v_day_id FROM training_plan_days
    WHERE plan_id = p_plan_id AND plan_date = v_plan_date;

    UPDATE training_plan_days
    SET title = v_day->>'title', focus = v_day->>'focus'
    WHERE id = v_day_id;

    DELETE FROM training_plan_exercises WHERE plan_day_id = v_day_id;

    FOR v_exercise IN SELECT * FROM jsonb_array_elements(coalesce(v_day->'exercises', '[]'::jsonb))
    LOOP
      v_exercise_id := gen_random_uuid();
      INSERT INTO training_plan_exercises (
        id, plan_id, plan_day_id, user_id, order_index, exercise_name, exercise_id,
        exercise_load_type, progression_mode, notes
      )
      VALUES (
        v_exercise_id, p_plan_id, v_day_id, p_user_id,
        (v_exercise->>'orderIndex')::int,
        v_exercise->>'exerciseName',
        v_exercise->>'exerciseId',
        coalesce(v_exercise->>'exerciseLoadType', 'unknown'),
        coalesce(v_exercise->>'progressionMode', 'ai_generated'),
        v_exercise->>'notes'
      );

      FOR v_set IN SELECT * FROM jsonb_array_elements(coalesce(v_exercise->'sets', '[]'::jsonb))
      LOOP
        INSERT INTO training_plan_sets (
          id, plan_id, plan_exercise_id, user_id, set_index,
          target_weight, target_weight_unit, target_reps
        )
        VALUES (
          gen_random_uuid(), p_plan_id, v_exercise_id, p_user_id,
          (v_set->>'setIndex')::int,
          (v_set->>'targetWeight')::numeric,
          coalesce(v_set->>'targetWeightUnit', 'kg'),
          (v_set->>'targetReps')::int
        );
      END LOOP;
    END LOOP;

    v_replanned_dates := v_replanned_dates || to_jsonb(v_plan_date::text);
  END LOOP;

  v_new_revision := v_plan_revision + 1;
  UPDATE training_plans SET revision = v_new_revision WHERE id = p_plan_id;

  RETURN jsonb_build_object('planId', p_plan_id, 'replannedDates', v_replanned_dates, 'newRevision', v_new_revision);
END;
$$;

REVOKE ALL ON FUNCTION replan_plan_days(uuid, uuid, jsonb, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION replan_plan_days(uuid, uuid, jsonb, int) FROM authenticated;
REVOKE ALL ON FUNCTION replan_plan_days(uuid, uuid, jsonb, int) FROM anon;
GRANT EXECUTE ON FUNCTION replan_plan_days(uuid, uuid, jsonb, int) TO service_role;

COMMENT ON FUNCTION replan_plan_days(uuid, uuid, jsonb, int) IS
  'Transactionally replaces one or more days of the current week''s active plan. Enforces C31 (never touch a past day or a day with completed sets) independent of the caller, plus an optimistic-lock revision check. service_role only.';
