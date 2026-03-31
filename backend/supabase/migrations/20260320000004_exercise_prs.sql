-- ============================================================
-- exercise_prs
-- Derived per-exercise PR records maintained by database triggers.
-- ============================================================

CREATE TABLE exercise_prs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  normalized_name varchar(255) NOT NULL,
  display_name varchar(255) NOT NULL,
  max_weight numeric(10,2) NOT NULL,
  weight_unit varchar(8) NOT NULL,
  source_set_id uuid REFERENCES exercise_sets(id) ON DELETE SET NULL,
  source_exercise_id uuid REFERENCES exercises(id) ON DELETE SET NULL,
  achieved_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, normalized_name)
);

ALTER TABLE exercise_prs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "exercise_prs_select_own" ON exercise_prs FOR SELECT USING (user_id = auth.uid());

CREATE INDEX idx_exercise_prs_user_name
  ON exercise_prs(user_id, normalized_name);

CREATE INDEX idx_exercise_prs_user_achieved_at
  ON exercise_prs(user_id, achieved_at DESC);

CREATE TRIGGER exercise_prs_updated_at
  BEFORE UPDATE ON exercise_prs
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

CREATE OR REPLACE VIEW profile_exercise_prs AS
SELECT
  user_id,
  normalized_name,
  display_name,
  max_weight,
  weight_unit,
  achieved_at
FROM exercise_prs;

ALTER VIEW profile_exercise_prs SET (security_invoker = true);

GRANT SELECT ON public.exercise_prs TO authenticated;
GRANT SELECT ON public.profile_exercise_prs TO authenticated;
GRANT ALL ON TABLE public.exercise_prs TO service_role;

-- ============================================================
-- refresh_exercise_prs_for_user
-- Rebuilds all exercise PRs for a single user.
-- ============================================================

CREATE OR REPLACE FUNCTION refresh_exercise_prs_for_user(v_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  WITH ranked_candidates AS (
    SELECT
      e.user_id,
      COALESCE(NULLIF(btrim(e.normalized_name), ''), lower(btrim(e.name))) AS normalized_name,
      e.name AS display_name,
      es.weight::numeric(10,2) AS max_weight,
      es.weight_unit,
      es.id AS source_set_id,
      e.id AS source_exercise_id,
      COALESCE(es.updated_at, es.created_at, e.updated_at, e.created_at, ws.updated_at, ws.created_at) AS achieved_at,
      ROW_NUMBER() OVER (
        PARTITION BY e.user_id, COALESCE(NULLIF(btrim(e.normalized_name), ''), lower(btrim(e.name)))
        ORDER BY
          es.weight DESC,
          COALESCE(es.updated_at, es.created_at, e.updated_at, e.created_at, ws.updated_at, ws.created_at) DESC,
          es.id DESC
      ) AS row_num
    FROM exercise_sets es
    JOIN exercises e ON e.id = es.exercise_id
    JOIN workout_sessions ws ON ws.id = e.session_id
    WHERE e.user_id = v_user_id
      AND es.weight IS NOT NULL
      AND es.deleted_at IS NULL
      AND e.deleted_at IS NULL
      AND ws.deleted_at IS NULL
  ), winners AS (
    SELECT
      user_id,
      normalized_name,
      display_name,
      max_weight,
      weight_unit,
      source_set_id,
      source_exercise_id,
      achieved_at
    FROM ranked_candidates
    WHERE row_num = 1
  )
  INSERT INTO exercise_prs (
    user_id,
    normalized_name,
    display_name,
    max_weight,
    weight_unit,
    source_set_id,
    source_exercise_id,
    achieved_at
  )
  SELECT
    user_id,
    normalized_name,
    display_name,
    max_weight,
    weight_unit,
    source_set_id,
    source_exercise_id,
    achieved_at
  FROM winners
  ON CONFLICT (user_id, normalized_name) DO UPDATE SET
    display_name = EXCLUDED.display_name,
    max_weight = EXCLUDED.max_weight,
    weight_unit = EXCLUDED.weight_unit,
    source_set_id = EXCLUDED.source_set_id,
    source_exercise_id = EXCLUDED.source_exercise_id,
    achieved_at = EXCLUDED.achieved_at,
    updated_at = now();

  DELETE FROM exercise_prs pr
  WHERE pr.user_id = v_user_id
    AND NOT EXISTS (
      SELECT 1
      FROM exercise_sets es
      JOIN exercises e ON e.id = es.exercise_id
      JOIN workout_sessions ws ON ws.id = e.session_id
      WHERE e.user_id = v_user_id
        AND COALESCE(NULLIF(btrim(e.normalized_name), ''), lower(btrim(e.name))) = pr.normalized_name
        AND es.weight IS NOT NULL
        AND es.deleted_at IS NULL
        AND e.deleted_at IS NULL
        AND ws.deleted_at IS NULL
    );
END;
$$;

-- ============================================================
-- refresh_user_stats
-- Extended to derive pr_count from exercise_prs.
-- ============================================================

CREATE OR REPLACE FUNCTION recompute_user_stats_for_user(v_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_streak int := 0;
  v_last_date date;
  v_check_date date;
  v_prev_date date;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  UPDATE user_stats SET
    workouts_count = (
      SELECT COUNT(*)
      FROM workout_sessions
      WHERE user_id = v_user_id AND deleted_at IS NULL
    ),
    total_volume = (
      SELECT COALESCE(SUM(es.weight * es.reps), 0)
      FROM exercise_sets es
      JOIN exercises e ON e.id = es.exercise_id
      JOIN workout_sessions ws ON ws.id = e.session_id
      WHERE ws.user_id = v_user_id
        AND es.deleted_at IS NULL
        AND e.deleted_at IS NULL
        AND ws.deleted_at IS NULL
    ),
    pr_count = (
      SELECT COUNT(*)
      FROM exercise_prs
      WHERE user_id = v_user_id
    ),
    last_workout_date = (
      SELECT MAX(workout_date)
      FROM workout_sessions
      WHERE user_id = v_user_id AND deleted_at IS NULL
    )
  WHERE user_id = v_user_id
  RETURNING last_workout_date INTO v_last_date;

  IF v_last_date IS NOT NULL THEN
    v_check_date := v_last_date;
    LOOP
      SELECT workout_date INTO v_prev_date
      FROM workout_sessions
      WHERE user_id = v_user_id
        AND workout_date = v_check_date
        AND deleted_at IS NULL
      LIMIT 1;

      EXIT WHEN v_prev_date IS NULL;
      v_streak := v_streak + 1;
      v_check_date := v_check_date - 1;
    END LOOP;
  END IF;

  UPDATE user_stats SET streak_days = v_streak
  WHERE user_id = v_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION refresh_user_stats()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := COALESCE(NEW.user_id, OLD.user_id);
  PERFORM recompute_user_stats_for_user(v_user_id);
  RETURN COALESCE(NEW, OLD);
END;
$$;

-- ============================================================
-- Trigger helpers for exercise-derived stats
-- ============================================================

CREATE OR REPLACE FUNCTION refresh_exercise_prs_and_stats_on_set_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := COALESCE(NEW.user_id, OLD.user_id);

  IF v_user_id IS NOT NULL THEN
    PERFORM refresh_exercise_prs_for_user(v_user_id);
    PERFORM recompute_user_stats_for_user(v_user_id);
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE FUNCTION refresh_exercise_prs_and_stats_on_exercise_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := COALESCE(NEW.user_id, OLD.user_id);

  IF v_user_id IS NOT NULL THEN
    PERFORM refresh_exercise_prs_for_user(v_user_id);
    PERFORM recompute_user_stats_for_user(v_user_id);
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER on_exercise_set_change_refresh_prs
  AFTER INSERT OR UPDATE OR DELETE ON exercise_sets
  FOR EACH ROW EXECUTE FUNCTION refresh_exercise_prs_and_stats_on_set_change();

CREATE TRIGGER on_exercise_change_refresh_prs
  AFTER UPDATE OR DELETE ON exercises
  FOR EACH ROW EXECUTE FUNCTION refresh_exercise_prs_and_stats_on_exercise_change();
