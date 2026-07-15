ALTER TABLE training_plan_exercises
  ADD COLUMN item_type varchar(16) NOT NULL DEFAULT 'strength',
  ADD COLUMN cardio_activity_type varchar(32),
  ADD COLUMN target_duration_minutes integer,
  ADD COLUMN target_distance_km numeric(8,2),
  ADD COLUMN target_rpe numeric(3,1),
  ADD COLUMN cardio_completed_at timestamptz,
  ADD COLUMN linked_cardio_workout_id uuid;

ALTER TABLE running_workouts
  ADD COLUMN activity_type varchar(32) NOT NULL DEFAULT 'running',
  ADD COLUMN rpe numeric(3,1),
  ALTER COLUMN distance_km DROP NOT NULL;

ALTER TABLE running_workouts
  DROP CONSTRAINT IF EXISTS running_workouts_distance_km_check,
  ADD CONSTRAINT running_workouts_activity_type_check
    CHECK (activity_type IN ('running', 'cycling', 'elliptical', 'stair_climber')),
  ADD CONSTRAINT running_workouts_distance_km_check
    CHECK (distance_km IS NULL OR distance_km > 0),
  ADD CONSTRAINT running_workouts_activity_distance_check
    CHECK (
      activity_type IN ('running', 'cycling')
      OR distance_km IS NULL
    ),
  ADD CONSTRAINT running_workouts_rpe_check
    CHECK (rpe IS NULL OR rpe BETWEEN 1 AND 10),
  ADD CONSTRAINT running_workouts_id_user_id_key UNIQUE (id, user_id);

ALTER TABLE training_plan_exercises
  ADD CONSTRAINT training_plan_exercises_item_type_check
    CHECK (item_type IN ('strength', 'cardio')),
  ADD CONSTRAINT training_plan_exercises_cardio_payload_check
    CHECK (
      (
        item_type = 'strength'
        AND cardio_activity_type IS NULL
        AND target_duration_minutes IS NULL
        AND target_distance_km IS NULL
        AND target_rpe IS NULL
        AND cardio_completed_at IS NULL
        AND linked_cardio_workout_id IS NULL
      )
      OR
      (
        item_type = 'cardio'
        AND cardio_activity_type IN ('running', 'cycling', 'elliptical', 'stair_climber')
        AND target_duration_minutes > 0
        AND (target_distance_km IS NULL OR target_distance_km > 0)
        AND (
          cardio_activity_type IN ('running', 'cycling')
          OR target_distance_km IS NULL
        )
        AND (target_rpe IS NULL OR target_rpe BETWEEN 1 AND 10)
      )
    ),
  ADD CONSTRAINT training_plan_exercises_linked_cardio_owner_fkey
    FOREIGN KEY (linked_cardio_workout_id, user_id)
    REFERENCES running_workouts (id, user_id);

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
  v_user_timezone := coalesce(v_user_timezone, 'UTC');
  v_current_week_monday := date_trunc('week', (now() AT TIME ZONE v_user_timezone))::date;
  v_target_week_start := (p_plan->>'weekStartDate')::date;

  IF v_target_week_start <= v_current_week_monday THEN
    RAISE EXCEPTION 'refusing to install a plan for the current or a past week (target %, current week %)',
      v_target_week_start, v_current_week_monday USING ERRCODE = 'check_violation';
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

  FOR v_day IN SELECT * FROM jsonb_array_elements(p_plan->'days') LOOP
    v_day_id := gen_random_uuid();
    INSERT INTO training_plan_days (id, plan_id, user_id, plan_date, day_index, title, focus, status)
    VALUES (
      v_day_id, v_plan_id, p_user_id, (v_day->>'planDate')::date,
      (v_day->>'dayIndex')::int, v_day->>'title', v_day->>'focus',
      coalesce(v_day->>'status', 'planned')
    );

    FOR v_exercise IN SELECT * FROM jsonb_array_elements(coalesce(v_day->'exercises', '[]'::jsonb)) LOOP
      v_exercise_id := gen_random_uuid();
      INSERT INTO training_plan_exercises (
        id, plan_id, plan_day_id, user_id, order_index, exercise_name, exercise_id,
        exercise_load_type, progression_mode, notes,
        item_type, cardio_activity_type, target_duration_minutes, target_distance_km, target_rpe
      ) VALUES (
        v_exercise_id, v_plan_id, v_day_id, p_user_id,
        (v_exercise->>'orderIndex')::int, v_exercise->>'exerciseName', v_exercise->>'exerciseId',
        coalesce(v_exercise->>'exerciseLoadType', 'unknown'),
        coalesce(v_exercise->>'progressionMode', 'ai_generated'), v_exercise->>'notes',
        coalesce(v_exercise->>'itemType', 'strength'), v_exercise->>'cardioActivityType',
        (v_exercise->>'targetDurationMinutes')::int,
        (v_exercise->>'targetDistanceKm')::numeric,
        (v_exercise->>'targetRPE')::numeric
      );

      FOR v_set IN SELECT * FROM jsonb_array_elements(coalesce(v_exercise->'sets', '[]'::jsonb)) LOOP
        INSERT INTO training_plan_sets (
          id, plan_id, plan_exercise_id, user_id, set_index,
          target_weight, target_weight_unit, target_reps
        ) VALUES (
          gen_random_uuid(), v_plan_id, v_exercise_id, p_user_id,
          (v_set->>'setIndex')::int, (v_set->>'targetWeight')::numeric,
          coalesce(v_set->>'targetWeightUnit', 'kg'), (v_set->>'targetReps')::int
        );
      END LOOP;
    END LOOP;
  END LOOP;

  UPDATE training_plans SET status = 'archived'
  WHERE user_id = p_user_id AND status = 'active'
    AND week_start_date < v_current_week_monday AND id != v_plan_id;
  GET DIAGNOSTICS v_archived_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'planId', v_plan_id, 'weekStartDate', v_target_week_start, 'archivedCount', v_archived_count
  );
END;
$$;

REVOKE ALL ON FUNCTION install_generated_plan(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION install_generated_plan(uuid, jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION install_generated_plan(uuid, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION install_generated_plan(uuid, jsonb) TO service_role;

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
  v_user_timezone := coalesce(v_user_timezone, 'UTC');
  v_today := (now() AT TIME ZONE v_user_timezone)::date;
  v_current_week_monday := date_trunc('week', (now() AT TIME ZONE v_user_timezone))::date;

  SELECT week_start_date, status, revision
  INTO v_plan_week_start, v_plan_status, v_plan_revision
  FROM training_plans WHERE id = p_plan_id AND user_id = p_user_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'plan % not found for user %', p_plan_id, p_user_id
      USING ERRCODE = 'no_data_found';
  END IF;
  IF v_plan_status != 'active' THEN
    RAISE EXCEPTION 'refusing to replan a non-active plan (status=%)', v_plan_status
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_plan_week_start != v_current_week_monday THEN
    RAISE EXCEPTION 'refusing to replan a plan that is not the current week (plan week %, current week %)',
      v_plan_week_start, v_current_week_monday USING ERRCODE = 'check_violation';
  END IF;
  IF v_plan_revision != p_expected_revision THEN
    RAISE EXCEPTION 'revision mismatch: expected %, actual % (plan changed since context was read)',
      p_expected_revision, v_plan_revision USING ERRCODE = 'serialization_failure';
  END IF;

  FOR v_day IN SELECT * FROM jsonb_array_elements(p_days) LOOP
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
      LEFT JOIN training_plan_sets s ON s.plan_exercise_id = e.id
      WHERE d.plan_id = p_plan_id AND d.plan_date = v_plan_date
        AND (
          s.completed_at IS NOT NULL OR s.linked_exercise_set_id IS NOT NULL
          OR e.cardio_completed_at IS NOT NULL OR e.linked_cardio_workout_id IS NOT NULL
        )
    ) THEN
      RAISE EXCEPTION 'refusing to replan a day with completed training (%)', v_plan_date
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  FOR v_day IN SELECT * FROM jsonb_array_elements(p_days) LOOP
    v_plan_date := (v_day->>'planDate')::date;
    SELECT id INTO v_day_id FROM training_plan_days
    WHERE plan_id = p_plan_id AND plan_date = v_plan_date;
    UPDATE training_plan_days SET title = v_day->>'title', focus = v_day->>'focus'
    WHERE id = v_day_id;
    DELETE FROM training_plan_exercises WHERE plan_day_id = v_day_id;

    FOR v_exercise IN SELECT * FROM jsonb_array_elements(coalesce(v_day->'exercises', '[]'::jsonb)) LOOP
      v_exercise_id := gen_random_uuid();
      INSERT INTO training_plan_exercises (
        id, plan_id, plan_day_id, user_id, order_index, exercise_name, exercise_id,
        exercise_load_type, progression_mode, notes,
        item_type, cardio_activity_type, target_duration_minutes, target_distance_km, target_rpe
      ) VALUES (
        v_exercise_id, p_plan_id, v_day_id, p_user_id,
        (v_exercise->>'orderIndex')::int, v_exercise->>'exerciseName', v_exercise->>'exerciseId',
        coalesce(v_exercise->>'exerciseLoadType', 'unknown'),
        coalesce(v_exercise->>'progressionMode', 'ai_generated'), v_exercise->>'notes',
        coalesce(v_exercise->>'itemType', 'strength'), v_exercise->>'cardioActivityType',
        (v_exercise->>'targetDurationMinutes')::int,
        (v_exercise->>'targetDistanceKm')::numeric,
        (v_exercise->>'targetRPE')::numeric
      );

      FOR v_set IN SELECT * FROM jsonb_array_elements(coalesce(v_exercise->'sets', '[]'::jsonb)) LOOP
        INSERT INTO training_plan_sets (
          id, plan_id, plan_exercise_id, user_id, set_index,
          target_weight, target_weight_unit, target_reps
        ) VALUES (
          gen_random_uuid(), p_plan_id, v_exercise_id, p_user_id,
          (v_set->>'setIndex')::int, (v_set->>'targetWeight')::numeric,
          coalesce(v_set->>'targetWeightUnit', 'kg'), (v_set->>'targetReps')::int
        );
      END LOOP;
    END LOOP;
    v_replanned_dates := v_replanned_dates || to_jsonb(v_plan_date::text);
  END LOOP;

  v_new_revision := v_plan_revision + 1;
  UPDATE training_plans SET revision = v_new_revision WHERE id = p_plan_id;
  RETURN jsonb_build_object(
    'planId', p_plan_id, 'replannedDates', v_replanned_dates, 'newRevision', v_new_revision
  );
END;
$$;

REVOKE ALL ON FUNCTION replan_plan_days(uuid, uuid, jsonb, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION replan_plan_days(uuid, uuid, jsonb, int) FROM authenticated;
REVOKE ALL ON FUNCTION replan_plan_days(uuid, uuid, jsonb, int) FROM anon;
GRANT EXECUTE ON FUNCTION replan_plan_days(uuid, uuid, jsonb, int) TO service_role;
