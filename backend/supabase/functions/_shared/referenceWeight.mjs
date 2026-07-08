// Deterministic double-progression arithmetic. Pure — no I/O, no LLM. The
// LLM receives this as a *suggestion* it may adopt or override; it never
// does this math itself (ADR-001: the LLM decides, the code computes).
//
// Consumed by contextBuilder.mjs per exercise, and independently unit-tested
// (backend/tests/referenceWeight.test.mjs) and via `node --test`.

export const BARBELL_STEP_KG = 2.5;
export const DUMBBELL_STEP_KG = 2;
export const DELOAD_FACTOR = 0.9;

const DUMBBELL_LIKE_EQUIPMENT = new Set(['dumbbell', 'kettlebell']);
const KG_PER_LB = 0.45359237;

export function lbsToKg(weightLbs) {
  return weightLbs * KG_PER_LB;
}

export function kgToDisplay(weightKg, unit) {
  if (weightKg == null) return null;
  return unit === 'lbs' ? weightKg / KG_PER_LB : weightKg;
}

/**
 * @param {object} params
 * @param {'bodyweight'|'weighted'|'unknown'} params.loadType
 * @param {string} params.equipment - Equipment raw value (barbell/dumbbell/machine/cable/bodyweight/kettlebell/other)
 * @param {Array<{allSetsHit: boolean, maxWeightKg: number|null, targetReps: number}>} params.recentOccurrences
 *        Most-recent-first. Each entry summarizes one past week's actual
 *        performance for this exercise (see contextBuilder.buildExerciseHistory).
 * @returns {{action: 'increase_weight'|'increase_reps'|'deload'|'hold', suggestedWeightKg: number|null, suggestedReps: number|null, rationale: string}}
 */
export function computeReferenceWeight({ loadType, equipment, recentOccurrences }) {
  if (!recentOccurrences || recentOccurrences.length === 0) {
    return { action: 'hold', suggestedWeightKg: null, suggestedReps: null, rationale: 'no history' };
  }

  const [last, secondLast] = recentOccurrences;

  if (loadType === 'bodyweight') {
    if (last.allSetsHit) {
      const bump = last.targetReps >= 10 ? 2 : 1;
      return {
        action: 'increase_reps',
        suggestedWeightKg: null,
        suggestedReps: (last.targetReps ?? 0) + bump,
        rationale: 'all sets hit last time; bodyweight progresses by reps, not load',
      };
    }
    return {
      action: 'hold',
      suggestedWeightKg: null,
      suggestedReps: last.targetReps,
      rationale: 'missed rep target last time; hold and retry',
    };
  }

  if (last.maxWeightKg == null) {
    return { action: 'hold', suggestedWeightKg: null, suggestedReps: last.targetReps, rationale: 'no weight on record' };
  }

  if (last.allSetsHit) {
    const step = DUMBBELL_LIKE_EQUIPMENT.has(equipment) ? DUMBBELL_STEP_KG : BARBELL_STEP_KG;
    return {
      action: 'increase_weight',
      suggestedWeightKg: last.maxWeightKg + step,
      suggestedReps: last.targetReps,
      rationale: 'all sets hit last time; progressive overload',
    };
  }

  if (secondLast && !secondLast.allSetsHit) {
    return {
      action: 'deload',
      suggestedWeightKg: Math.round(last.maxWeightKg * DELOAD_FACTOR * 2) / 2, // nearest 0.5kg
      suggestedReps: last.targetReps,
      rationale: 'missed target two occurrences in a row; deload 10%',
    };
  }

  return {
    action: 'hold',
    suggestedWeightKg: last.maxWeightKg,
    suggestedReps: last.targetReps,
    rationale: 'missed target once; hold weight and retry',
  };
}
