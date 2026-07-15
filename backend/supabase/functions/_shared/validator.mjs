// Safety-only validation of an LLM-generated weekly plan. Never makes
// training decisions — only clamps unsafe values (weight jumps) or flags
// structural defects for the repair loop / fallback path. See ADR-001 and
// docs/plans/2026-07-08-phase2-weekly-generation-plan.md §3.1/§5.

export const MIN_REPS = 1;
export const MAX_REPS = 30;
export const MAX_WEEKLY_INCREASE_FACTOR = 1.10;
export const NO_HISTORY_CAP_FACTOR = 0.90;
export const CARDIO_ACTIVITY_TYPES = new Set(['running', 'cycling', 'elliptical', 'stair_climber']);

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
 * Shared safety checks for one day's exercises: unknown library ids, reps
 * range, missing weight on weighted exercises, and weekly-load clamping.
 * Used by both the full-week validator and the replan validator so the two
 * can never quietly diverge on what counts as an unsafe number.
 */
function clampDayExercises(day, dayIndex, context, structuralViolations, verdicts) {
  const knownIds = new Set((context.library ?? []).map((e) => e.id));
  const exercises = Array.isArray(day.exercises) ? day.exercises : [];

  const clampedExercises = exercises.map((exercise) => {
    const itemType = exercise.itemType ?? 'strength';
    if (itemType === 'cardio') {
      const activityType = exercise.cardioActivityType;
      if (exercise.exerciseId != null) {
        structuralViolations.push(
          `day ${dayIndex} exercise "${exercise.exerciseName}": cardio exerciseId must be null`
        );
      }
      if (exercise.loadType != null) {
        structuralViolations.push(
          `day ${dayIndex} exercise "${exercise.exerciseName}": cardio loadType must be null`
        );
      }
      if (!CARDIO_ACTIVITY_TYPES.has(activityType)) {
        structuralViolations.push(
          `day ${dayIndex} exercise "${exercise.exerciseName}": unknown cardioActivityType "${activityType}"`
        );
      }
      if (!Number.isInteger(exercise.targetDurationMinutes) || exercise.targetDurationMinutes <= 0) {
        structuralViolations.push(
          `day ${dayIndex} exercise "${exercise.exerciseName}": duration must be a positive integer`
        );
      }
      if (exercise.targetDistanceKm != null &&
          (typeof exercise.targetDistanceKm !== 'number' || exercise.targetDistanceKm <= 0)) {
        structuralViolations.push(
          `day ${dayIndex} exercise "${exercise.exerciseName}": distance must be positive when present`
        );
      }
      if ((activityType === 'elliptical' || activityType === 'stair_climber') &&
          exercise.targetDistanceKm != null) {
        structuralViolations.push(
          `day ${dayIndex} exercise "${exercise.exerciseName}": ${activityType} does not support distance`
        );
      }
      if (Array.isArray(exercise.sets) && exercise.sets.length > 0) {
        structuralViolations.push(
          `day ${dayIndex} exercise "${exercise.exerciseName}": cardio item must not contain strength sets`
        );
      }
      return { ...exercise, itemType, targetRPE: null, sets: [] };
    }

    if (itemType !== 'strength') {
      structuralViolations.push(`day ${dayIndex}: unknown itemType "${itemType}"`);
    }
    if (exercise.cardioActivityType != null || exercise.targetDurationMinutes != null ||
        exercise.targetDistanceKm != null || exercise.targetRPE != null) {
      structuralViolations.push(
        `day ${dayIndex} exercise "${exercise.exerciseName ?? exercise.exerciseId}": strength item contains cardio fields`
      );
    }

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

    return { ...exercise, itemType, sets: clampedSets };
  });

  return { ...day, exercises: clampedExercises };
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

  const clampedDays = plan.days.map((day, dayIndex) => clampDayExercises(day, dayIndex, context, structuralViolations, verdicts));

  return {
    ok: structuralViolations.length === 0,
    structuralViolations,
    verdicts,
    clampedPlan: { ...plan, days: clampedDays },
  };
}

/**
 * Validates a mid-week replan response (Phase 3): unlike the full weekly
 * plan, there is no fixed "7 days" or "daysPerWeek" expectation — the LLM is
 * only replanning a caller-given subset of days (the ones still eligible,
 * i.e. not in the past and not already trained). Structural correctness
 * here means exactly: the plan covers exactly the target dates, no more, no
 * less. Safety checks (library ids, reps range, weight clamping) are
 * identical to the weekly validator — reused via clampDayExercises so the
 * two paths can't drift on what counts as unsafe.
 *
 * @param {object} plan - raw LLM output: { days: [{ planDate, title, focus, exercises: [...] }] }
 * @param {string[]} targetDates - the exact set of yyyy-MM-dd dates the caller asked to be replanned
 * @param {object} context - ContextBuilder output (see contextBuilder.mjs buildReplanContext)
 * @returns {{ok: boolean, structuralViolations: string[], verdicts: object[], clampedPlan: object|null}}
 */
export function validateReplanDays(plan, targetDates, context) {
  const structuralViolations = [];
  const verdicts = [];

  if (!plan || !Array.isArray(plan.days)) {
    return { ok: false, structuralViolations: ['plan.days is missing or not an array'], verdicts: [], clampedPlan: null };
  }

  const expected = new Set(targetDates);
  const got = new Set(plan.days.map((d) => d.planDate));

  for (const date of expected) {
    if (!got.has(date)) structuralViolations.push(`missing replanned day for ${date}`);
  }
  for (const date of got) {
    if (!expected.has(date)) structuralViolations.push(`unexpected day ${date} — not in the target date set`);
  }
  if (plan.days.length !== new Set(plan.days.map((d) => d.planDate)).size) {
    structuralViolations.push('duplicate planDate entries in replanned days');
  }

  const clampedDays = plan.days.map((day, dayIndex) => clampDayExercises(day, dayIndex, context, structuralViolations, verdicts));

  return {
    ok: structuralViolations.length === 0,
    structuralViolations,
    verdicts,
    clampedPlan: { ...plan, days: clampedDays },
  };
}
