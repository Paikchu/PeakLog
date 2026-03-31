-- ============================================================
-- PeakLog Schema Migration
-- ============================================================

-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "moddatetime";

-- ============================================================
-- 1. profiles
-- Business-side user info, linked to auth.users
-- ============================================================
CREATE TABLE profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name varchar(100) NOT NULL DEFAULT 'PeakLog User',
  avatar_url text,
  membership_type varchar(32) NOT NULL DEFAULT 'free',
  timezone varchar(64) NOT NULL DEFAULT 'UTC',
  status varchar(32) NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "profiles_select_own" ON profiles FOR SELECT USING (id = auth.uid());
CREATE POLICY "profiles_update_own" ON profiles FOR UPDATE USING (id = auth.uid());

CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- ============================================================
-- 2. user_preferences
-- ============================================================
CREATE TABLE user_preferences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid UNIQUE NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  notifications_enabled boolean NOT NULL DEFAULT true,
  dark_mode_enabled boolean NOT NULL DEFAULT false,
  weight_unit varchar(8) NOT NULL DEFAULT 'kg',
  distance_unit varchar(8) NOT NULL DEFAULT 'km',
  language varchar(16) NOT NULL DEFAULT 'en',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE user_preferences ENABLE ROW LEVEL SECURITY;
CREATE POLICY "user_preferences_all_own" ON user_preferences FOR ALL USING (user_id = auth.uid());

CREATE TRIGGER user_preferences_updated_at
  BEFORE UPDATE ON user_preferences
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- ============================================================
-- 3. user_stats
-- Aggregated stats, maintained by triggers
-- ============================================================
CREATE TABLE user_stats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid UNIQUE NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  workouts_count int NOT NULL DEFAULT 0,
  streak_days int NOT NULL DEFAULT 0,
  total_volume numeric(18,2) NOT NULL DEFAULT 0,
  pr_count int NOT NULL DEFAULT 0,
  last_workout_date date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE user_stats ENABLE ROW LEVEL SECURITY;
CREATE POLICY "user_stats_select_own" ON user_stats FOR SELECT USING (user_id = auth.uid());

CREATE TRIGGER user_stats_updated_at
  BEFORE UPDATE ON user_stats
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- ============================================================
-- 4. conversations
-- ============================================================
CREATE TABLE conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title varchar(255),
  conversation_type varchar(32) NOT NULL DEFAULT 'default',
  last_message_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "conversations_all_own" ON conversations FOR ALL USING (user_id = auth.uid());

CREATE INDEX idx_conversations_user ON conversations(user_id, updated_at DESC);

CREATE TRIGGER conversations_updated_at
  BEFORE UPDATE ON conversations
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- ============================================================
-- 5. messages
-- User messages + AI replies. Realtime CDC enabled below.
-- content_blocks (jsonb) drives GenUI rendering on iOS.
-- ============================================================
CREATE TABLE messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role varchar(16) NOT NULL CHECK (role IN ('user','assistant','system')),
  client_message_id varchar(100),
  input_type varchar(32) NOT NULL DEFAULT 'text',
  content text,
  content_blocks jsonb,
  status varchar(32) NOT NULL DEFAULT 'created',
  parse_status varchar(32),
  reply_to_message_id uuid REFERENCES messages(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
CREATE POLICY "messages_select_own" ON messages FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "messages_insert_own" ON messages FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "messages_update_own" ON messages FOR UPDATE USING (user_id = auth.uid());

-- Idempotency: prevent duplicate client messages
CREATE UNIQUE INDEX idx_messages_idempotency
  ON messages(user_id, conversation_id, client_message_id)
  WHERE client_message_id IS NOT NULL;

CREATE INDEX idx_messages_conversation ON messages(conversation_id, created_at ASC);
CREATE INDEX idx_messages_user ON messages(user_id, created_at DESC);
CREATE INDEX idx_messages_content_blocks ON messages USING GIN (content_blocks jsonb_path_ops);

CREATE TRIGGER messages_updated_at
  BEFORE UPDATE ON messages
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- Enable Realtime for messages table (iOS subscribes for live AI responses)
ALTER PUBLICATION supabase_realtime ADD TABLE messages;

-- ============================================================
-- 6. attachments
-- ============================================================
CREATE TABLE attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  message_id uuid REFERENCES messages(id) ON DELETE SET NULL,
  file_type varchar(32) NOT NULL,
  file_name varchar(255),
  mime_type varchar(128),
  file_size bigint,
  storage_key text NOT NULL,
  processing_status varchar(32) NOT NULL DEFAULT 'uploaded',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

ALTER TABLE attachments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "attachments_all_own" ON attachments FOR ALL USING (user_id = auth.uid());

CREATE INDEX idx_attachments_user ON attachments(user_id, created_at DESC);
CREATE INDEX idx_attachments_message ON attachments(message_id);

CREATE TRIGGER attachments_updated_at
  BEFORE UPDATE ON attachments
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- ============================================================
-- 7. parse_tasks
-- ============================================================
CREATE TABLE parse_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  task_type varchar(32) NOT NULL,
  status varchar(32) NOT NULL DEFAULT 'queued',
  error_code varchar(64),
  error_message text,
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE parse_tasks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "parse_tasks_select_own" ON parse_tasks FOR SELECT USING (user_id = auth.uid());

CREATE INDEX idx_parse_tasks_message ON parse_tasks(message_id);
CREATE INDEX idx_parse_tasks_status ON parse_tasks(status, created_at ASC);

CREATE TRIGGER parse_tasks_updated_at
  BEFORE UPDATE ON parse_tasks
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- ============================================================
-- 8. parse_results
-- ============================================================
CREATE TABLE parse_results (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parse_task_id uuid NOT NULL REFERENCES parse_tasks(id) ON DELETE CASCADE,
  version int NOT NULL DEFAULT 1,
  parser_type varchar(32) NOT NULL DEFAULT 'llm',
  confidence_score numeric(5,4),
  result_json jsonb NOT NULL DEFAULT '{}',
  ambiguities_json jsonb,
  is_final boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE parse_results ENABLE ROW LEVEL SECURITY;
CREATE POLICY "parse_results_select_own" ON parse_results FOR SELECT
  USING (parse_task_id IN (SELECT id FROM parse_tasks WHERE user_id = auth.uid()));

CREATE UNIQUE INDEX idx_parse_results_version ON parse_results(parse_task_id, version);

-- ============================================================
-- 9. workout_sessions
-- ============================================================
CREATE TABLE workout_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  source_message_id uuid REFERENCES messages(id) ON DELETE SET NULL,
  workout_date date NOT NULL,
  title varchar(255),
  source_type varchar(32) NOT NULL DEFAULT 'chat',
  parse_status varchar(32) NOT NULL DEFAULT 'completed',
  confirmation_status varchar(32) NOT NULL DEFAULT 'confirmed',
  started_at timestamptz,
  ended_at timestamptz,
  duration_seconds int,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

ALTER TABLE workout_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "workout_sessions_all_own" ON workout_sessions FOR ALL USING (user_id = auth.uid());

CREATE INDEX idx_workout_sessions_user_date
  ON workout_sessions(user_id, workout_date DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX idx_workout_sessions_source ON workout_sessions(source_message_id);

CREATE TRIGGER workout_sessions_updated_at
  BEFORE UPDATE ON workout_sessions
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- ============================================================
-- 10. exercises
-- ============================================================
CREATE TABLE exercises (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES workout_sessions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name varchar(255) NOT NULL,
  normalized_name varchar(255),
  muscle_group varchar(64),
  order_index int NOT NULL DEFAULT 0,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

ALTER TABLE exercises ENABLE ROW LEVEL SECURITY;
CREATE POLICY "exercises_all_own" ON exercises FOR ALL USING (user_id = auth.uid());

CREATE INDEX idx_exercises_session
  ON exercises(session_id, order_index)
  WHERE deleted_at IS NULL;

CREATE INDEX idx_exercises_user_name
  ON exercises(user_id, normalized_name)
  WHERE deleted_at IS NULL;

CREATE TRIGGER exercises_updated_at
  BEFORE UPDATE ON exercises
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- ============================================================
-- 11. exercise_sets
-- ============================================================
CREATE TABLE exercise_sets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  exercise_id uuid NOT NULL REFERENCES exercises(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  set_index int NOT NULL DEFAULT 1,
  weight numeric(10,2),
  weight_unit varchar(8) NOT NULL DEFAULT 'kg',
  reps int,
  rpe numeric(4,2),
  duration_seconds int,
  distance numeric(10,2),
  distance_unit varchar(8),
  calories numeric(10,2),
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

ALTER TABLE exercise_sets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "exercise_sets_all_own" ON exercise_sets FOR ALL USING (user_id = auth.uid());

CREATE INDEX idx_exercise_sets_exercise
  ON exercise_sets(exercise_id, set_index)
  WHERE deleted_at IS NULL;

CREATE INDEX idx_exercise_sets_user ON exercise_sets(user_id, created_at DESC);

CREATE TRIGGER exercise_sets_updated_at
  BEFORE UPDATE ON exercise_sets
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- ============================================================
-- 12. audit_logs
-- ============================================================
CREATE TABLE audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  entity_type varchar(64) NOT NULL,
  entity_id uuid NOT NULL,
  action varchar(64) NOT NULL,
  operator_type varchar(32) NOT NULL DEFAULT 'system',
  operator_id uuid,
  before_json jsonb,
  after_json jsonb,
  metadata_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "audit_logs_select_own" ON audit_logs FOR SELECT USING (user_id = auth.uid());
-- Insert is restricted to service_role (Edge Functions use service_role key internally)
CREATE POLICY "audit_logs_insert_service" ON audit_logs FOR INSERT WITH CHECK (true);

CREATE INDEX idx_audit_logs_user ON audit_logs(user_id, created_at DESC);
CREATE INDEX idx_audit_logs_entity ON audit_logs(entity_type, entity_id);

-- ============================================================
-- Grant service_role access to all tables (used by Edge Functions)
-- ============================================================
GRANT ALL ON TABLE public.conversations TO service_role;
GRANT ALL ON TABLE public.messages TO service_role;
GRANT ALL ON TABLE public.workout_sessions TO service_role;
GRANT ALL ON TABLE public.exercises TO service_role;
GRANT ALL ON TABLE public.exercise_sets TO service_role;
GRANT ALL ON TABLE public.audit_logs TO service_role;
