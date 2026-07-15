CREATE INDEX IF NOT EXISTS training_plan_exercises_linked_cardio_owner_idx
  ON public.training_plan_exercises (linked_cardio_workout_id, user_id);
