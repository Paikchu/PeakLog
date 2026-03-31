ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS fitness_goal_summary text;

CREATE TABLE IF NOT EXISTS training_plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  week_start_date date NOT NULL,
  status varchar(32) NOT NULL DEFAULT 'active',
  goal_snapshot text,
  coach_summary text NOT NULL,
  source_message_id uuid REFERENCES messages(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_training_plans_active_week
  ON training_plans(user_id, week_start_date);

CREATE TABLE IF NOT EXISTS training_plan_days (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id uuid NOT NULL REFERENCES training_plans(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  plan_date date NOT NULL,
  day_index int NOT NULL,
  title varchar(255) NOT NULL,
  focus text,
  status varchar(32) NOT NULL DEFAULT 'planned',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS training_plan_exercises (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id uuid NOT NULL REFERENCES training_plans(id) ON DELETE CASCADE,
  plan_day_id uuid NOT NULL REFERENCES training_plan_days(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  order_index int NOT NULL DEFAULT 0,
  exercise_name varchar(255) NOT NULL,
  progression_mode varchar(32) NOT NULL DEFAULT 'maintain',
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS training_plan_sets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id uuid NOT NULL REFERENCES training_plans(id) ON DELETE CASCADE,
  plan_exercise_id uuid NOT NULL REFERENCES training_plan_exercises(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  set_index int NOT NULL,
  target_weight numeric(10,2),
  target_weight_unit varchar(8) NOT NULL DEFAULT 'kg',
  target_reps int NOT NULL,
  completed_at timestamptz,
  linked_exercise_set_id uuid REFERENCES exercise_sets(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE training_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE training_plan_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE training_plan_exercises ENABLE ROW LEVEL SECURITY;
ALTER TABLE training_plan_sets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "training_plans_all_own" ON training_plans FOR ALL USING (user_id = auth.uid());
CREATE POLICY "training_plan_days_all_own" ON training_plan_days FOR ALL USING (user_id = auth.uid());
CREATE POLICY "training_plan_exercises_all_own" ON training_plan_exercises FOR ALL USING (user_id = auth.uid());
CREATE POLICY "training_plan_sets_all_own" ON training_plan_sets FOR ALL USING (user_id = auth.uid());

CREATE TRIGGER training_plans_updated_at
  BEFORE UPDATE ON training_plans
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

CREATE TRIGGER training_plan_days_updated_at
  BEFORE UPDATE ON training_plan_days
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

CREATE TRIGGER training_plan_exercises_updated_at
  BEFORE UPDATE ON training_plan_exercises
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

CREATE TRIGGER training_plan_sets_updated_at
  BEFORE UPDATE ON training_plan_sets
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);
