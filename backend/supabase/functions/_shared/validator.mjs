// Safety-only validation of an LLM-generated weekly plan. Never makes
// training decisions — only clamps unsafe values (weight jumps) or flags
// structural defects for the repair loop / fallback path. See ADR-001 and
// docs/plans/2026-07-08-phase2-weekly-generation-plan.md §3.1/§5.

export const MIN_REPS = 1;
export const MAX_REPS = 30;
export const MAX_WEEKLY_INCREASE_FACTOR = 1.10;
export const NO_HISTORY_CAP_FACTOR = 0.90;

/**
 * The 7 dates (yyyy-MM-dd, UTC) a plan starting on `weekStartDate` must cover.
 */
export function weekDates(weekStartDate) {
  const start = new Date(`${weekStartDate}T00:00:00Z`);
  return Array.from({ length: 7 }, (_, i) => {
    const d = new Date(start);
    d.setUTCDate(start.getUTCDate() + i);
    return d.toISOString().slice(0, 10);
  });
}

/**
 * @param {object} plan - raw LLM output: { days: [{ dayIndex, planDate, title, focus, exercises: [...] }] }
 * @param {object} context - ContextBuilder output (see contextBuilder.mjs)
 * @returns {{ok: boolean, structuralViolations: string[], verdicts: object[], clampedPlan: object|null}}
 *   `ok: true` means clampedPlan is safe to install as-is. `ok: false` means
 *   structuralViolations must be fed back into an LLM repair request (or, if
 *   repairs are exhausted, the caller falls back to repeating the current week.
 */
export function validateWeeklyPlan(plan, context) {
  const structuralViolations = [];
  const verdicts = [];

  if (!plan || !Array.isArray(plan.days)) {
    return { ok: false, structuralViolations: ['plan.days is missing or not an array'], verdicts: [], clampedPlan: null };
  }

  if (plan.days.length !== 7) {
    structuralViolations.push(`expected 7 days, got ${plan.days.length}`);
  }

  const expectedDates = weekDates(context.weekStartDate);
  plan.days.forEach((day, index) => {
    const expected = expectedDates[index];
    if (expected && day.planDate !== expected) {
      structuralViolations.push(`day ${index}: expected planDate ${expected}, got ${day.planDate}`);
    }
  });

  const trainingDayCount = plan.days.filter((d) => Array.isArray(d.exercises) && d.exercises.length > 0).length;
  const expectedTrainingDays = context.goalSpec?.daysPerWeek;
  if (expectedTrainingDays != null && trainingDayCount !== expectedTrainingDays) {
    structuralViolations.push(`expected ${expectedTrainingDays} training days, got ${trainingDayCount}`);
  }

  const knownIds = new Set((context.library ?? []).map((e) => e.id));

  const clampedDays = plan.days.map((day, dayIndex) => {
    const exercises = Array.isArray(day.exercises) ? day.exercises : [];
    const clampedExercises = exercises.map((exercise) => {
      if (exercise.exerciseId && !knownIds.has(exercise.exerciseId)) {
        structuralViolations.push(`day ${dayIndex}: unknown exerciseId "${exercise.exerciseId}"`);
      }

      const isBodyweight = exercise.loadType === 'bodyweight';
      const history = context.exerciseHistory?.[exercise.exerciseId];
      const cap = history?.occurrences?.[0]?.maxWeightKg != null
        ? history.occurrences[0].maxWeightKg * MAX_WEEKLY_INCREASE_FACTOR
        : (history?.referenceMaxKg != null ? history.referenceMaxKg * NO_HISTORY_CAP_FACTOR : null);

      const sets = Array.isArray(exercise.sets) ? exercise.sets : [];
      const clampedSets = sets.map((set, setIndex) => {
        if (!Number.isInteger(set.targetReps) || set.targetReps < MIN_REPS || set.targetReps > MAX_REPS) {
          structuralViolations.push(
            `day ${dayIndex} exercise "${exercise.exerciseName ?? exercise.exerciseId}" set ${setIndex}: reps ${set.targetReps} out of range [${MIN_REPS},${MAX_REPS}]`
          );
        }
        if (!isBodyweight && set.targetWeight == null) {
          structuralViolations.push(
            `day ${dayIndex} exercise "${exercise.exerciseName ?? exercise.exerciseId}" set ${setIndex}: weighted exercise missing target weight`
          );
        }

        let targetWeight = set.targetWeight;
        if (targetWeight != null && cap != null && targetWeight > cap) {
          verdicts.push({
            exerciseId: exercise.exerciseId,
            exerciseName: exercise.exerciseName,
            setIndex,
            action: 'clamped',
            from: targetWeight,
            to: cap,
            reason: history?.occurrences?.[0]?.maxWeightKg != null
              ? 'exceeds 110% of last actual weight'
              : 'exceeds 90% of reference max with no logged history',
          });
          targetWeight = cap;
        }
        return { ...set, targetWeight };
      });

      return { ...exercise, sets: clampedSets };
    });
    return { ...day, exercises: clampedExercises };
  });

  return {
    ok: structuralViolations.length === 0,
    structuralViolations,
    verdicts,
    clampedPlan: { ...plan, days: clampedDays },
  };
}
