-- ============================================================
-- Phase 2: install_generated_plan RPC + scheduling extensions.
-- See docs/plans/2026-07-08-phase2-weekly-generation-plan.md §3.3/§3.5.
-- Applied to fqyurmsuvtdafbnynurg on 2026-07-08 via MCP (as two migrations,
-- since a security issue was caught and fixed live — see note below; this
-- file represents the corrected end state, not the intermediate one).
--
-- Extensions are enabled here; the actual cron.schedule() call is deferred
-- to a later migration once the Edge Function is deployed and dry_run
-- verified (plan §7 step 6) — enabling infrastructure and turning on
-- traffic are separate, independently-revertible steps.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- ============================================================
-- install_generated_plan: single-transaction installer for a
-- server-generated weekly plan. SECURITY DEFINER, callable only by
-- service_role — the Edge Function is the only intended caller.
--
-- Hard safety invariant (C21, user-mandated): this function must NEVER
-- write to, or archive-touch the content of, the week currently in
-- progress or any past week. It enforces this itself, independent of
-- whatever the caller computed as the "target week" — a bug upstream
-- cannot make this function overwrite a week the user might be mid-set on.
--
-- SECURITY NOTE (found live during Phase 2 implementation, worth keeping
-- as a comment so it isn't reintroduced): newly created functions in this
-- project's public schema pick up an EXECUTE grant for the `anon` role by
-- default — `REVOKE ALL ... FROM PUBLIC` alone does NOT remove it, meaning
-- `anon` holds it via a standalone or default-privilege grant, not via
-- PUBLIC. For a SECURITY DEFINER function that trusts p_user_id with no
-- internal check, that would let an unauthenticated request write a plan
-- for any user. Fixed two ways: an explicit `REVOKE ... FROM anon`, and an
-- in-function `auth.role()` check as defense in depth so this can't
-- silently regress again even if a future migration's grants are wrong.
-- Verified live against the real HTTP endpoint: both anon and an
-- authenticated user's own token get a hard 401/403 permission-denied.
-- ============================================================
CREATE OR REPLACE FUNCTION install_generated_plan(p_user_id uuid, p_plan jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_timezone text;
  v_current_week_monday date;
  v_target_week_start date;
  v_plan_id uuid := gen_random_uuid();
  v_day jsonb;
  v_day_id uuid;
  v_exercise jsonb;
  v_exercise_id uuid;
  v_set jsonb;
  v_archived_count int;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'install_generated_plan may only be called by service_role'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT timezone INTO v_user_timezone FROM profiles WHERE id = p_user_id;
  IF v_user_timezone IS NULL THEN
    v_user_timezone := 'UTC';
  END IF;

  -- date_trunc('week', ...) truncates to the Monday of the ISO week,
  -- matching the app's own Monday-first week convention.
  v_current_week_monday := date_trunc('week', (now() AT TIME ZONE v_user_timezone))::date;
  v_target_week_start := (p_plan->>'weekStartDate')::date;

  IF v_target_week_start <= v_current_week_monday THEN
    RAISE EXCEPTION 'refusing to install a plan for the current or a past week (target %, current week %)',
      v_target_week_start, v_current_week_monday
      USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (
    SELECT 1 FROM training_plans WHERE user_id = p_user_id AND week_start_date = v_target_week_start
  ) THEN
    RAISE EXCEPTION 'a plan for week % already exists for user %', v_target_week_start, p_user_id
      USING ERRCODE = 'unique_violation';
  END IF;

  INSERT INTO training_plans (id, user_id, week_start_date, status, goal_snapshot, coach_summary)
  VALUES (
    v_plan_id, p_user_id, v_target_week_start, 'active',
    p_plan->>'goalSnapshot', coalesce(p_plan->>'coachSummary', '')
  );

  FOR v_day IN SELECT * FROM jsonb_array_elements(p_plan->'days')
  LOOP
    v_day_id := gen_random_uuid();
    INSERT INTO training_plan_days (id, plan_id, user_id, plan_date, day_index, title, focus, status)
    VALUES (
      v_day_id, v_plan_id, p_user_id,
      (v_day->>'planDate')::date,
      (v_day->>'dayIndex')::int,
      v_day->>'title',
      v_day->>'focus',
      coalesce(v_day->>'status', 'planned')
    );

    FOR v_exercise IN SELECT * FROM jsonb_array_elements(coalesce(v_day->'exercises', '[]'::jsonb))
    LOOP
      v_exercise_id := gen_random_uuid();
      INSERT INTO training_plan_exercises (
        id, plan_id, plan_day_id, user_id, order_index, exercise_name, exercise_id,
        exercise_load_type, progression_mode, notes
      )
      VALUES (
        v_exercise_id, v_plan_id, v_day_id, p_user_id,
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
          gen_random_uuid(), v_plan_id, v_exercise_id, p_user_id,
          (v_set->>'setIndex')::int,
          (v_set->>'targetWeight')::numeric,
          coalesce(v_set->>'targetWeightUnit', 'kg'),
          (v_set->>'targetReps')::int
        );
      END LOOP;
    END LOOP;
  END LOOP;

  -- Lazy archival: only weeks strictly BEFORE the current week are ever
  -- touched, and only their status column — never their content, and never
  -- the week actually in progress right now. This is what self-heals the
  -- known client behavior of re-marking a stale pulled plan 'active'
  -- (Phase 2 plan §4.3 / SY1/SY2 from Phase 1).
  UPDATE training_plans
  SET status = 'archived'
  WHERE user_id = p_user_id
    AND status = 'active'
    AND week_start_date < v_current_week_monday
    AND id != v_plan_id;
  GET DIAGNOSTICS v_archived_count = ROW_COUNT;

  RETURN jsonb_build_object('planId', v_plan_id, 'weekStartDate', v_target_week_start, 'archivedCount', v_archived_count);
END;
$$;

REVOKE ALL ON FUNCTION install_generated_plan(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION install_generated_plan(uuid, jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION install_generated_plan(uuid, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION install_generated_plan(uuid, jsonb) TO service_role;

COMMENT ON FUNCTION install_generated_plan(uuid, jsonb) IS
  'Single-transaction installer for a server-generated weekly plan. Enforces C21 (never touch the current or a past week) independent of the caller. service_role only.';

-- ============================================================
-- Vault secret for cron -> Edge Function authentication (plan §3.4/§3.5).
-- The generate-weekly-plan function checks this value against the
-- x-generation-secret header on cron-triggered calls. Idempotent: skipped
-- if a secret with this name already exists (e.g. re-running on a branch).
-- The SAME value must also be set as an Edge Function secret when the
-- function is deployed (Phase 2 plan §7 step 4) — that half can't happen
-- here since it's a Deno runtime env var, not a Postgres object.
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'generation_secret') THEN
    PERFORM vault.create_secret(
      encode(gen_random_bytes(32), 'hex'),
      'generation_secret',
      'Shared secret the generate-weekly-plan Edge Function checks in the x-generation-secret header on cron-triggered calls. Not a DB credential.'
    );
  END IF;
END $$;
