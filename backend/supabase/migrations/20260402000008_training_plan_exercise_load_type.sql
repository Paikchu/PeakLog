ALTER TABLE training_plan_exercises
ADD COLUMN IF NOT EXISTS exercise_load_type varchar(16) NOT NULL DEFAULT 'unknown';

UPDATE training_plan_exercises
SET exercise_load_type = CASE
  WHEN EXISTS (
    SELECT 1
    FROM training_plan_sets
    WHERE training_plan_sets.plan_exercise_id = training_plan_exercises.id
      AND training_plan_sets.target_weight IS NOT NULL
  ) THEN 'weighted'
  ELSE 'unknown'
END
WHERE exercise_load_type = 'unknown';

ALTER TABLE training_plan_exercises
DROP CONSTRAINT IF EXISTS training_plan_exercises_exercise_load_type_check;

ALTER TABLE training_plan_exercises
ADD CONSTRAINT training_plan_exercises_exercise_load_type_check
CHECK (exercise_load_type IN ('bodyweight', 'weighted', 'unknown'));
