-- Preserve the library slug on planned exercises (parity with exercises.exercise_id).
-- Applied to fqyurmsuvtdafbnynurg on 2026-07-07 via MCP.
ALTER TABLE training_plan_exercises
  ADD COLUMN IF NOT EXISTS exercise_id text;
