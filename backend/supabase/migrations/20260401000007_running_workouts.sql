CREATE TABLE IF NOT EXISTS running_workouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  source_message_id uuid REFERENCES messages(id) ON DELETE SET NULL,
  workout_date date NOT NULL,
  duration_minutes integer NOT NULL CHECK (duration_minutes > 0),
  distance_km numeric(6,2) NOT NULL CHECK (distance_km > 0),
  source varchar(16) NOT NULL DEFAULT 'chat',
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

ALTER TABLE running_workouts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "running_workouts_all_own" ON running_workouts
  FOR ALL USING (user_id = auth.uid());

CREATE INDEX idx_running_workouts_user_date
  ON running_workouts(user_id, workout_date DESC, created_at ASC);

CREATE INDEX idx_running_workouts_source_message
  ON running_workouts(source_message_id);

CREATE TRIGGER running_workouts_updated_at
  BEFORE UPDATE ON running_workouts
  FOR EACH ROW
  EXECUTE FUNCTION moddatetime(updated_at);

GRANT ALL ON TABLE public.running_workouts TO service_role;
