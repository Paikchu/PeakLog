// Pure transformation: raw Postgres rows -> the fact JSON handed to the LLM.
// No network calls here — the Edge Function fetches rows, this module only
// computes. See docs/plans/2026-07-08-phase2-weekly-generation-plan.md §3.1.

import { computeReferenceWeight } from './referenceWeight.mjs';

const EPLEY_DIVISOR = 30;
const KG_PER_LB = 0.45359237;
const MAX_RECENT_EVENTS = 30; // keeps the prompt bounded (C20-adjacent)

export function normalizeToKg(weight, unit) {
  if (weight == null) return null;
  return unit === 'lbs' ? weight * KG_PER_LB : weight;
}

export function estimateOneRepMax(weightKg, reps) {
  if (weightKg == null || reps == null || reps <= 0) return null;
  if (reps === 1) return weightKg;
  return weightKg * (1 + reps / EPLEY_DIVISOR);
}

/** Fraction of planned sets actually completed, across the plan-set rows given. */
export function computeAdherence(planSetRows) {
  const total = planSetRows.length;
  if (total === 0) return { completed: 0, total: 0, rate: null };
  const completed = planSetRows.filter((s) => s.completed_at != null || s.linked_exercise_set_id != null).length;
  return { completed, total, rate: completed / total };
}

function groupBy(rows, key) {
  return rows.reduce((acc, row) => {
    (acc[row[key]] ??= []).push(row);
    return acc;
  }, {});
}

/**
 * Builds per-exercise progression history from linked plan/actual sets.
 *
 * `planExerciseRows` must be pre-sorted oldest-week-first by the caller (each
 * week contributes its own training_plan_exercises row for the same
 * exercise_id) — this function pushes occurrences in that order per exercise
 * then reverses to most-recent-first, so callers get the ordering
 * `computeReferenceWeight` expects without contextBuilder re-deriving week
 * order from unrelated tables.
 *
 * "allSetsHit" means every linked actual set met the *plan's own* target rep
 * count — there's no target on a raw logged set, so this is only knowable via
 * the plan_set -> exercise_set link. Occurrences with no linked actual sets
 * are skipped (nothing to compare against yet).
 */
export function buildExerciseHistory({ planExerciseRows, planSetRows, actualSetsById, equipmentByExerciseId = {} }) {
  const history = {};
  const setsByPlanExercise = groupBy(planSetRows, 'plan_exercise_id');

  for (const planExercise of planExerciseRows) {
    const exerciseId = planExercise.exercise_id;
    if (!exerciseId) continue;

    const sets = setsByPlanExercise[planExercise.id] ?? [];
    const linked = sets
      .filter((s) => s.linked_exercise_set_id && actualSetsById[s.linked_exercise_set_id])
      .map((s) => ({ planSet: s, actual: actualSetsById[s.linked_exercise_set_id] }));
    if (linked.length === 0) continue;

    const allSetsHit = linked.every(({ planSet, actual }) => (actual.reps ?? 0) >= planSet.target_reps);
    const weightedSets = linked
      .map(({ actual }) => ({ weightKg: normalizeToKg(actual.weight, actual.weight_unit), reps: actual.reps }))
      .filter((s) => s.weightKg != null);
    // "Top set" for this occurrence: the heaviest logged set, used both as
    // maxWeightKg (feeds computeReferenceWeight's step logic) and as the
    // basis for this occurrence's e1RM (feeds the trend series below).
    const topSet = weightedSets.reduce((best, cur) => (best == null || cur.weightKg > best.weightKg ? cur : best), null);
    const maxWeightKg = topSet?.weightKg ?? null;
    const e1RM = topSet ? estimateOneRepMax(topSet.weightKg, topSet.reps) : null;
    const targetReps = linked[0].planSet.target_reps;

    history[exerciseId] ??= {
      displayName: planExercise.exercise_name,
      loadType: planExercise.exercise_load_type,
      equipment: equipmentByExerciseId[exerciseId] ?? 'other',
      occurrences: [],
    };
    history[exerciseId].occurrences.push({ allSetsHit, maxWeightKg, targetReps, e1RM });
  }

  for (const exerciseId of Object.keys(history)) {
    const entry = history[exerciseId];
    entry.occurrences.reverse(); // oldest-first (push order) -> most-recent-first
    entry.e1RMSeries = entry.occurrences.map((o) => o.e1RM).filter((v) => v != null);
    entry.reference = computeReferenceWeight({
      loadType: entry.loadType,
      equipment: entry.equipment,
      recentOccurrences: entry.occurrences,
    });
  }

  return history;
}

export function summarizeEditEvents(editEventRows, { maxRecent = MAX_RECENT_EVENTS } = {}) {
  const byType = {};
  for (const event of editEventRows) {
    byType[event.event_type] = (byType[event.event_type] ?? 0) + 1;
  }
  const recent = [...editEventRows]
    .sort((a, b) => new Date(b.occurred_at) - new Date(a.occurred_at))
    .slice(0, maxRecent)
    .map((e) => ({ type: e.event_type, exerciseName: e.exercise_name, occurredAt: e.occurred_at, payload: e.payload }));
  return { totalCount: editEventRows.length, byType, recent };
}

export function projectGoalSpec(goalSpecRow) {
  if (!goalSpecRow) {
    return {
      objective: 'general', daysPerWeek: 3, sessionMinutes: 60,
      equipment: [], focusAreas: [], experience: 'beginner', note: null, isDefault: true,
    };
  }
  return {
    objective: goalSpecRow.objective,
    daysPerWeek: goalSpecRow.days_per_week,
    sessionMinutes: goalSpecRow.session_minutes,
    equipment: goalSpecRow.equipment ?? [],
    focusAreas: goalSpecRow.focus_areas ?? [],
    experience: goalSpecRow.experience,
    note: goalSpecRow.note ?? null,
    isDefault: false,
  };
}

/**
 * Per-day overview of the CURRENT week's plan, for replan context (Phase 3):
 * what's already there, and whether each day already has any completed sets.
 * `hasCompletedSets` is only what's *shown* to the LLM (and to the caller
 * for computing which dates to even offer as targets) — the real safety
 * enforcement happens independently inside replan_plan_days (C31), this is
 * not itself a security boundary.
 *
 * @param {object} input
 * @param {Array} input.dayRows - training_plan_days rows for the current week's plan
 * @param {Array} input.exerciseRows - training_plan_exercises rows for those days
 * @param {Array} input.setRows - training_plan_sets rows for those exercises
 */
export function summarizeCurrentWeekDays({ dayRows, exerciseRows, setRows }) {
  const setsByExercise = groupBy(setRows, 'plan_exercise_id');
  const exercisesByDay = groupBy(exerciseRows, 'plan_day_id');

  return [...dayRows]
    .sort((a, b) => a.day_index - b.day_index)
    .map((day) => {
      const exercises = (exercisesByDay[day.id] ?? []).map((ex) => {
        const sets = setsByExercise[ex.id] ?? [];
        return {
          exerciseName: ex.exercise_name,
          exerciseId: ex.exercise_id,
          targetReps: sets.map((s) => s.target_reps),
          completedCount: sets.filter((s) => s.completed_at != null || s.linked_exercise_set_id != null).length,
          totalCount: sets.length,
        };
      });
      return {
        planDate: day.plan_date,
        title: day.title,
        focus: day.focus ?? null,
        exercises,
        hasCompletedSets: exercises.some((e) => e.completedCount > 0),
      };
    });
}

export function projectLibrary(libraryExercises, customExercises = []) {
  const seed = libraryExercises.map((e) => ({
    id: e.id, nameEN: e.nameEN, nameZH: e.nameZH,
    muscleGroup: e.muscleGroup, equipment: e.equipment, loadType: e.loadType,
  }));
  const custom = customExercises.map((c) => ({
    id: `custom-${c.id}`, nameEN: c.name_en, nameZH: c.name_zh,
    muscleGroup: c.muscle_group, equipment: c.equipment, loadType: c.load_type,
  }));
  return [...seed, ...custom];
}

/**
 * @param {object} input
 * @param {object|null} input.goalSpecRow
 * @param {string} input.weightUnit - user_preferences.weight_unit
 * @param {string} input.language - user_preferences.language
 * @param {Array} input.planExerciseRows - training_plan_exercises across the lookback window, oldest week first
 * @param {Array} input.planSetRows - training_plan_sets across the same window
 * @param {Object<string, object>} input.actualSetsById - exercise_sets rows keyed by id
 * @param {Array} input.editEventRows - plan_edit_events, source='user', lookback window
 * @param {Array} input.libraryExercises - bundled exercise_library.json entries
 * @param {Array} input.customExercises - custom_exercises rows for this user
 * @param {string} input.weekStartDate - the Monday of the week being generated FOR
 * @param {string|null} input.libraryVersion
 * @returns {object} the fact JSON fed to the LLM
 */
export function buildContext({
  goalSpecRow, weightUnit, language,
  planExerciseRows, planSetRows, actualSetsById,
  editEventRows, libraryExercises, customExercises,
  weekStartDate, libraryVersion,
}) {
  const equipmentByExerciseId = {};
  for (const e of libraryExercises) equipmentByExerciseId[e.id] = e.equipment;
  for (const c of customExercises ?? []) equipmentByExerciseId[`custom-${c.id}`] = c.equipment;

  const adherence = computeAdherence(planSetRows);
  const exerciseHistory = buildExerciseHistory({ planExerciseRows, planSetRows, actualSetsById, equipmentByExerciseId });
  const isColdStart = adherence.total === 0 && Object.keys(exerciseHistory).length === 0;

  return {
    weekStartDate,
    weightUnit: weightUnit ?? 'kg',
    language: language ?? 'en',
    isColdStart,
    goalSpec: projectGoalSpec(goalSpecRow),
    adherence,
    exerciseHistory,
    editEvents: summarizeEditEvents(editEventRows ?? []),
    library: projectLibrary(libraryExercises, customExercises),
    libraryVersion: libraryVersion ?? null,
  };
}

/**
 * The fact JSON for a mid-week replan (Phase 3): everything buildContext
 * already assembles (goalSpec, exerciseHistory, library, adherence, edit
 * events) PLUS the current week's full day-by-day state and which dates are
 * actually eligible to be rewritten. `weekStartDate` here is the CURRENT
 * week being replanned, not the next week a weekly generation would target.
 *
 * @param {object} input - everything buildContext takes, plus:
 * @param {Array} input.currentWeekDayRows - training_plan_days for the current week's plan
 * @param {Array} input.currentWeekExerciseRows - training_plan_exercises for those days
 * @param {Array} input.currentWeekSetRows - training_plan_sets for those exercises
 * @param {string[]} input.targetDates - dates the LLM is being asked to replan
 * @param {string|null} input.signal - 'skip_today' | 'low_energy' | 'time_limited' | null (inference-triggered)
 */
export function buildReplanContext({
  currentWeekDayRows, currentWeekExerciseRows, currentWeekSetRows,
  targetDates, signal,
  ...rest
}) {
  const base = buildContext(rest);
  return {
    ...base,
    replan: {
      signal: signal ?? null,
      targetDates,
      currentWeekOverview: summarizeCurrentWeekDays({
        dayRows: currentWeekDayRows,
        exerciseRows: currentWeekExerciseRows,
        setRows: currentWeekSetRows,
      }),
    },
  };
}
