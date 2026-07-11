-- Remove legacy rows whose claimed owner does not match their parent.
-- Parent deletes cascade, so cleanup proceeds from the top of the hierarchy.
DELETE FROM training_plan_days AS day
WHERE NOT EXISTS (
  SELECT 1 FROM training_plans AS plan
  WHERE plan.id = day.plan_id AND plan.user_id = day.user_id
);

DELETE FROM training_plan_exercises AS exercise
WHERE NOT EXISTS (
  SELECT 1 FROM training_plans AS plan
  WHERE plan.id = exercise.plan_id AND plan.user_id = exercise.user_id
)
OR NOT EXISTS (
  SELECT 1 FROM training_plan_days AS day
  WHERE day.id = exercise.plan_day_id
    AND day.plan_id = exercise.plan_id
    AND day.user_id = exercise.user_id
);

DELETE FROM training_plan_sets AS plan_set
WHERE NOT EXISTS (
  SELECT 1 FROM training_plans AS plan
  WHERE plan.id = plan_set.plan_id AND plan.user_id = plan_set.user_id
)
OR NOT EXISTS (
  SELECT 1 FROM training_plan_exercises AS exercise
  WHERE exercise.id = plan_set.plan_exercise_id
    AND exercise.plan_id = plan_set.plan_id
    AND exercise.user_id = plan_set.user_id
);

UPDATE training_plan_sets AS plan_set
SET linked_exercise_set_id = NULL
WHERE linked_exercise_set_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM exercise_sets AS actual_set
    WHERE actual_set.id = plan_set.linked_exercise_set_id
      AND actual_set.user_id = plan_set.user_id
  );

ALTER TABLE training_plans
  ADD CONSTRAINT training_plans_id_user_id_key UNIQUE (id, user_id);

ALTER TABLE training_plan_days
  ADD CONSTRAINT training_plan_days_id_plan_user_key UNIQUE (id, plan_id, user_id),
  ADD CONSTRAINT training_plan_days_plan_owner_fkey
    FOREIGN KEY (plan_id, user_id)
    REFERENCES training_plans (id, user_id) ON DELETE CASCADE;

ALTER TABLE training_plan_exercises
  ADD CONSTRAINT training_plan_exercises_id_plan_user_key UNIQUE (id, plan_id, user_id),
  ADD CONSTRAINT training_plan_exercises_plan_owner_fkey
    FOREIGN KEY (plan_id, user_id)
    REFERENCES training_plans (id, user_id) ON DELETE CASCADE,
  ADD CONSTRAINT training_plan_exercises_day_owner_fkey
    FOREIGN KEY (plan_day_id, plan_id, user_id)
    REFERENCES training_plan_days (id, plan_id, user_id) ON DELETE CASCADE;

ALTER TABLE exercise_sets
  ADD CONSTRAINT exercise_sets_id_user_id_key UNIQUE (id, user_id);

ALTER TABLE training_plan_sets
  ADD CONSTRAINT training_plan_sets_plan_owner_fkey
    FOREIGN KEY (plan_id, user_id)
    REFERENCES training_plans (id, user_id) ON DELETE CASCADE,
  ADD CONSTRAINT training_plan_sets_exercise_owner_fkey
    FOREIGN KEY (plan_exercise_id, plan_id, user_id)
    REFERENCES training_plan_exercises (id, plan_id, user_id) ON DELETE CASCADE,
  ADD CONSTRAINT training_plan_sets_linked_set_owner_fkey
    FOREIGN KEY (linked_exercise_set_id, user_id)
    REFERENCES exercise_sets (id, user_id) ON DELETE SET NULL (linked_exercise_set_id);
