-- ============================================================
-- Cardio plan items: a target may be duration, distance, or both.
--
-- WHY
--
-- 20260715145641_add_cardio_training_plan.sql required
-- `target_duration_minutes > 0` on every cardio item, so distance was only
-- ever an *extra* qualifier on a duration target. That does not match how
-- people actually plan a run: "5 km" is a complete goal on its own, and the
-- app's add-exercise sheet kept Save disabled until a duration was typed in
-- even when a distance had been entered.
--
-- The relaxed rule is "at least one of the two, positive when present". Both
-- being NULL is still rejected — a cardio item with no target at all is not a
-- plan, it is a row nobody can act on.
--
-- Elliptical and stair climber are unchanged: they still cannot carry a
-- distance, which means duration remains effectively required for them and
-- the at-least-one clause degrades to "duration is not null".
--
-- COMPATIBILITY
--
-- Strictly widening: every row that satisfied the old predicate satisfies the
-- new one, so the re-validating ADD CONSTRAINT cannot fail on existing data
-- and nothing needs backfilling. Rolling back means restoring the old
-- predicate, which only succeeds once any distance-only rows written in the
-- meantime are given a duration.
-- ============================================================

ALTER TABLE training_plan_exercises
  DROP CONSTRAINT IF EXISTS training_plan_exercises_cardio_payload_check;

ALTER TABLE training_plan_exercises
  ADD CONSTRAINT training_plan_exercises_cardio_payload_check
    CHECK (
      (
        item_type = 'strength'
        AND cardio_activity_type IS NULL
        AND target_duration_minutes IS NULL
        AND target_distance_km IS NULL
        AND target_rpe IS NULL
        AND cardio_completed_at IS NULL
        AND linked_cardio_workout_id IS NULL
      )
      OR
      (
        item_type = 'cardio'
        AND cardio_activity_type IN ('running', 'cycling', 'elliptical', 'stair_climber')
        AND (target_duration_minutes IS NOT NULL OR target_distance_km IS NOT NULL)
        AND (target_duration_minutes IS NULL OR target_duration_minutes > 0)
        AND (target_distance_km IS NULL OR target_distance_km > 0)
        AND (
          cardio_activity_type IN ('running', 'cycling')
          OR target_distance_km IS NULL
        )
        AND (target_rpe IS NULL OR target_rpe BETWEEN 1 AND 10)
      )
    );
