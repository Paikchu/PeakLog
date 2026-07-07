-- ============================================================
-- Remove chat-era pipeline; keep training core only.
-- Adds custom_exercises for exercise-library sync.
-- Note: chat-attachments storage bucket must be deleted via
-- Storage API / Dashboard (SQL deletion is blocked).
-- Applied to fqyurmsuvtdafbnynurg on 2026-07-07 via MCP.
-- ============================================================

-- 1. Drop chat-referencing columns on core tables
ALTER TABLE workout_sessions DROP COLUMN IF EXISTS source_message_id;
ALTER TABLE workout_sessions DROP COLUMN IF EXISTS parse_status;
ALTER TABLE workout_sessions DROP COLUMN IF EXISTS confirmation_status;
ALTER TABLE workout_sessions ALTER COLUMN source_type SET DEFAULT 'manual';
ALTER TABLE running_workouts DROP COLUMN IF EXISTS source_message_id;
ALTER TABLE running_workouts ALTER COLUMN source SET DEFAULT 'manual';
ALTER TABLE training_plans DROP COLUMN IF EXISTS source_message_id;

-- 2. Drop chat pipeline tables (children first; CASCADE clears dependent triggers/policies)
DROP TABLE IF EXISTS conversation_pending_actions CASCADE;
DROP TABLE IF EXISTS parse_results CASCADE;
DROP TABLE IF EXISTS parse_tasks CASCADE;
DROP TABLE IF EXISTS attachments CASCADE;
DROP TABLE IF EXISTS messages CASCADE;
DROP TABLE IF EXISTS conversations CASCADE;
DROP TABLE IF EXISTS audit_logs CASCADE;

-- 3. Drop chat-only trigger function
DROP FUNCTION IF EXISTS update_conversation_last_message_at();

-- 4. handle_new_user no longer creates a default conversation
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_display_name text;
BEGIN
  v_display_name := NULLIF(btrim(COALESCE(
    NEW.raw_user_meta_data->>'full_name',
    concat_ws(' ', NEW.raw_user_meta_data->>'given_name', NEW.raw_user_meta_data->>'family_name')
  )), '');

  INSERT INTO public.profiles (id, display_name, timezone)
  VALUES (NEW.id, COALESCE(v_display_name, 'PeakLog User'), 'UTC');

  INSERT INTO public.user_preferences (user_id) VALUES (NEW.id);
  INSERT INTO public.user_stats (user_id) VALUES (NEW.id);

  RETURN NEW;
END;
$$;

-- 5. Remove chat-attachments storage policy (bucket removal is manual)
DROP POLICY IF EXISTS "chat_attachments_all_own" ON storage.objects;

-- 6. custom_exercises: user-defined exercise-library entries
CREATE TABLE IF NOT EXISTS custom_exercises (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name_en varchar(255) NOT NULL,
  name_zh varchar(255) NOT NULL,
  aliases text[] NOT NULL DEFAULT '{}',
  muscle_group varchar(64) NOT NULL,
  equipment varchar(32) NOT NULL DEFAULT 'other',
  load_type varchar(16) NOT NULL DEFAULT 'unknown'
    CHECK (load_type IN ('bodyweight', 'weighted', 'unknown')),
  popularity int NOT NULL DEFAULT 50,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, name_en)
);

ALTER TABLE custom_exercises ENABLE ROW LEVEL SECURITY;
CREATE POLICY "custom_exercises_all_own" ON custom_exercises FOR ALL USING (user_id = auth.uid());

CREATE INDEX idx_custom_exercises_user ON custom_exercises(user_id, updated_at DESC);

CREATE TRIGGER custom_exercises_updated_at
  BEFORE UPDATE ON custom_exercises
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

GRANT ALL ON TABLE custom_exercises TO service_role;
