-- ============================================================
-- PeakLog Trigger Functions
-- ============================================================

-- ============================================================
-- 1. handle_new_user
-- Auto-create profile, preferences, stats, and default
-- conversation when a new auth.users row is inserted.
-- ============================================================
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_conversation_id uuid;
BEGIN
  -- Create profile
  INSERT INTO public.profiles (id, display_name, timezone)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email, 'PeakLog User'),
    'UTC'
  );

  -- Create default preferences
  INSERT INTO public.user_preferences (user_id)
  VALUES (NEW.id);

  -- Create stats row
  INSERT INTO public.user_stats (user_id)
  VALUES (NEW.id);

  -- Create a default conversation for the user
  INSERT INTO public.conversations (user_id, title, conversation_type)
  VALUES (NEW.id, 'My Workout Log', 'default')
  RETURNING id INTO v_conversation_id;

  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ============================================================
-- 2. refresh_user_stats
-- Recalculate user_stats whenever a workout_session changes.
-- Also computes streak_days from consecutive workout dates.
-- ============================================================
CREATE OR REPLACE FUNCTION refresh_user_stats()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_streak int := 0;
  v_last_date date;
  v_check_date date;
  v_prev_date date;
BEGIN
  v_user_id := COALESCE(NEW.user_id, OLD.user_id);

  -- Count and volume
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
    last_workout_date = (
      SELECT MAX(workout_date)
      FROM workout_sessions
      WHERE user_id = v_user_id AND deleted_at IS NULL
    )
  WHERE user_id = v_user_id
  RETURNING last_workout_date INTO v_last_date;

  -- Compute streak_days
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

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER on_workout_session_change
  AFTER INSERT OR UPDATE OR DELETE ON workout_sessions
  FOR EACH ROW EXECUTE FUNCTION refresh_user_stats();

-- ============================================================
-- 3. cascade_soft_delete_exercise
-- When an exercise is soft-deleted, cascade to its sets.
-- ============================================================
CREATE OR REPLACE FUNCTION cascade_soft_delete_exercise()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    UPDATE exercise_sets
    SET deleted_at = NEW.deleted_at
    WHERE exercise_id = NEW.id AND deleted_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_exercise_soft_delete
  AFTER UPDATE ON exercises
  FOR EACH ROW EXECUTE FUNCTION cascade_soft_delete_exercise();

-- ============================================================
-- 4. update_conversation_last_message_at
-- Keep conversations.last_message_at current.
-- ============================================================
CREATE OR REPLACE FUNCTION update_conversation_last_message_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  UPDATE conversations
  SET last_message_at = NEW.created_at
  WHERE id = NEW.conversation_id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_message_inserted
  AFTER INSERT ON messages
  FOR EACH ROW EXECUTE FUNCTION update_conversation_last_message_at();
