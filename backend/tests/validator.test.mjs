import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  validateWeeklyPlan,
  validateReplanDays,
  weekDates,
  MAX_WEEKLY_INCREASE_FACTOR,
  NO_HISTORY_CAP_FACTOR,
} from '../supabase/functions/_shared/validator.mjs';

const WEEK_START = '2026-07-13'; // a Monday

function baseContext(overrides = {}) {
  return {
    weekStartDate: WEEK_START,
    goalSpec: { daysPerWeek: 3 },
    exerciseHistory: {},
    library: [
      { id: 'barbell-bench-press', nameEN: 'Bench Press', equipment: 'barbell', loadType: 'weighted' },
      { id: 'pull-up', nameEN: 'Pull Up', equipment: 'bodyweight', loadType: 'bodyweight' },
    ],
    ...overrides,
  };
}

function dayWith(dayIndex, exercises) {
  return { dayIndex, planDate: weekDates(WEEK_START)[dayIndex], title: 'Day', focus: null, exercises };
}

function restDay(dayIndex) {
  return { dayIndex, planDate: weekDates(WEEK_START)[dayIndex], title: 'Rest', focus: null, exercises: [] };
}

function validExercise() {
  return {
    exerciseId: 'barbell-bench-press',
    exerciseName: 'Bench Press',
    loadType: 'weighted',
    notes: null,
    sets: [{ setIndex: 1, targetWeight: 60, targetWeightUnit: 'kg', targetReps: 8 }],
  };
}

function validCardio(overrides = {}) {
  return {
    itemType: 'cardio',
    exerciseId: null,
    exerciseName: 'Running',
    loadType: null,
    cardioActivityType: 'running',
    targetDurationMinutes: 30,
    targetDistanceKm: 5,
    notes: null,
    sets: [],
    ...overrides,
  };
}

function validSevenDayPlan() {
  return {
    days: [
      dayWith(0, [validExercise()]),
      restDay(1),
      dayWith(2, [validExercise()]),
      restDay(3),
      dayWith(4, [validExercise()]),
      restDay(5),
      restDay(6),
    ],
    coachSummary: 'Solid week ahead.',
  };
}

test('weekDates produces 7 consecutive calendar dates', () => {
  const dates = weekDates(WEEK_START);
  assert.equal(dates.length, 7);
  assert.equal(dates[0], '2026-07-13');
  assert.equal(dates[6], '2026-07-19');
});

test('a well-formed plan matching goalSpec passes clean', () => {
  const result = validateWeeklyPlan(validSevenDayPlan(), baseContext());
  assert.equal(result.ok, true);
  assert.deepEqual(result.structuralViolations, []);
  assert.deepEqual(result.verdicts, []);
});

test('wrong day count is rejected', () => {
  const plan = validSevenDayPlan();
  plan.days.pop();
  const result = validateWeeklyPlan(plan, baseContext());
  assert.equal(result.ok, false);
  assert.ok(result.structuralViolations.some((v) => v.includes('expected 7 days')));
});

test('wrong planDate sequence is rejected', () => {
  const plan = validSevenDayPlan();
  plan.days[3].planDate = '2099-01-01';
  const result = validateWeeklyPlan(plan, baseContext());
  assert.equal(result.ok, false);
  assert.ok(result.structuralViolations.some((v) => v.includes('day 3')));
});

test('training day count must match goalSpec.daysPerWeek', () => {
  const plan = validSevenDayPlan();
  plan.days[1].exercises = [validExercise()]; // now 4 training days, goal says 3
  const result = validateWeeklyPlan(plan, baseContext());
  assert.equal(result.ok, false);
  assert.ok(result.structuralViolations.some((v) => v.includes('expected 3 training days, got 4')));
});

test('unknown exerciseId is rejected (never invented by the model)', () => {
  const plan = validSevenDayPlan();
  plan.days[0].exercises[0].exerciseId = 'made-up-exercise';
  const result = validateWeeklyPlan(plan, baseContext());
  assert.equal(result.ok, false);
  assert.ok(result.structuralViolations.some((v) => v.includes('unknown exerciseId')));
});

test('null exerciseId (no library match) is allowed, not flagged', () => {
  const plan = validSevenDayPlan();
  plan.days[0].exercises[0].exerciseId = null;
  const result = validateWeeklyPlan(plan, baseContext());
  assert.equal(result.ok, true);
});

test('reps out of [1,30] range is rejected', () => {
  const plan = validSevenDayPlan();
  plan.days[0].exercises[0].sets[0].targetReps = 45;
  const result = validateWeeklyPlan(plan, baseContext());
  assert.equal(result.ok, false);
  assert.ok(result.structuralViolations.some((v) => v.includes('out of range')));
});

test('weighted exercise missing a target weight is rejected', () => {
  const plan = validSevenDayPlan();
  plan.days[0].exercises[0].sets[0].targetWeight = null;
  const result = validateWeeklyPlan(plan, baseContext());
  assert.equal(result.ok, false);
  assert.ok(result.structuralViolations.some((v) => v.includes('missing target weight')));
});

test('bodyweight exercise with null weight is fine', () => {
  const plan = validSevenDayPlan();
  plan.days[0].exercises[0] = {
    exerciseId: 'pull-up',
    exerciseName: 'Pull Up',
    loadType: 'bodyweight',
    notes: null,
    sets: [{ setIndex: 1, targetWeight: null, targetWeightUnit: 'kg', targetReps: 10 }],
  };
  const result = validateWeeklyPlan(plan, baseContext());
  assert.equal(result.ok, true);
});

test('running and cycling accept duration with optional distance', () => {
  const plan = validSevenDayPlan();
  plan.days[0].exercises.push(validCardio());
  plan.days[2].exercises = [validCardio({
    exerciseName: 'Cycling',
    cardioActivityType: 'cycling',
    targetDistanceKm: null,
  })];
  const result = validateWeeklyPlan(plan, baseContext());
  assert.equal(result.ok, true, result.structuralViolations.join('\n'));
});

test('elliptical and stair climber reject distance but accept duration', () => {
  const validPlan = validSevenDayPlan();
  validPlan.days[0].exercises = [validCardio({
    exerciseName: 'Elliptical',
    cardioActivityType: 'elliptical',
    targetDistanceKm: null,
  })];
  assert.equal(validateWeeklyPlan(validPlan, baseContext()).ok, true);

  const invalidPlan = validSevenDayPlan();
  invalidPlan.days[0].exercises = [validCardio({
    exerciseName: 'Stair Climber',
    cardioActivityType: 'stair_climber',
    targetDistanceKm: 2,
  })];
  const result = validateWeeklyPlan(invalidPlan, baseContext());
  assert.equal(result.ok, false);
  assert.ok(result.structuralViolations.some((v) => v.includes('does not support distance')));
});

test('cardio contract rejects unknown type, invalid metrics, and strength sets', () => {
  const cases = [
    [validCardio({ cardioActivityType: 'swimming' }), 'unknown cardioActivityType'],
    [validCardio({ targetDurationMinutes: 0 }), 'duration'],
    [validCardio({ targetDistanceKm: -1 }), 'distance'],
    [validCardio({ sets: validExercise().sets }), 'must not contain strength sets'],
    [validCardio({ exerciseId: 'bench_press' }), 'exerciseId must be null'],
    [validCardio({ loadType: 'weighted' }), 'loadType must be null'],
  ];
  for (const [cardio, message] of cases) {
    const plan = validSevenDayPlan();
    plan.days[0].exercises = [cardio];
    const result = validateWeeklyPlan(plan, baseContext());
    assert.equal(result.ok, false, message);
    assert.ok(result.structuralViolations.some((v) => v.includes(message)), result.structuralViolations.join('\n'));
  }
});

test('legacy cardio targetRPE is normalized away', () => {
  const plan = validSevenDayPlan();
  plan.days[0].exercises = [validCardio({ targetRPE: 8 })];
  const result = validateWeeklyPlan(plan, baseContext());
  assert.equal(result.ok, true, result.structuralViolations.join('\n'));
  assert.equal(result.clampedPlan.days[0].exercises[0].targetRPE, null);
});

test('strength items reject cardio-only fields', () => {
  const plan = validSevenDayPlan();
  plan.days[0].exercises[0].itemType = 'strength';
  plan.days[0].exercises[0].targetDurationMinutes = 20;
  const result = validateWeeklyPlan(plan, baseContext());
  assert.equal(result.ok, false);
  assert.ok(result.structuralViolations.some((v) => v.includes('strength item contains cardio fields')));
});

test('weight exceeding 110% of last actual is clamped in place, not rejected', () => {
  const plan = validSevenDayPlan();
  plan.days[0].exercises[0].sets[0].targetWeight = 100; // way over
  const context = baseContext({
    exerciseHistory: {
      'barbell-bench-press': { occurrences: [{ allSetsHit: true, maxWeightKg: 60, targetReps: 8 }] },
    },
  });
  const result = validateWeeklyPlan(plan, context);
  assert.equal(result.ok, true, 'clamping must not fail the plan');
  const cap = 60 * MAX_WEEKLY_INCREASE_FACTOR;
  assert.equal(result.clampedPlan.days[0].exercises[0].sets[0].targetWeight, cap);
  assert.equal(result.verdicts.length, 1);
  assert.equal(result.verdicts[0].action, 'clamped');
  assert.equal(result.verdicts[0].to, cap);
});

test('weight within 110% of last actual is left untouched', () => {
  const plan = validSevenDayPlan();
  plan.days[0].exercises[0].sets[0].targetWeight = 62.5; // last actual 60, cap is 66
  const context = baseContext({
    exerciseHistory: {
      'barbell-bench-press': { occurrences: [{ allSetsHit: true, maxWeightKg: 60, targetReps: 8 }] },
    },
  });
  const result = validateWeeklyPlan(plan, context);
  assert.equal(result.verdicts.length, 0);
  assert.equal(result.clampedPlan.days[0].exercises[0].sets[0].targetWeight, 62.5);
});

test('no logged history but a reference max exists -> clamp to 90% of reference', () => {
  const plan = validSevenDayPlan();
  plan.days[0].exercises[0].sets[0].targetWeight = 100;
  const context = baseContext({
    exerciseHistory: {
      'barbell-bench-press': { occurrences: [], referenceMaxKg: 80 },
    },
  });
  const result = validateWeeklyPlan(plan, context);
  const cap = 80 * NO_HISTORY_CAP_FACTOR;
  assert.equal(result.clampedPlan.days[0].exercises[0].sets[0].targetWeight, cap);
});

test('completely new exercise, no history and no reference -> no cap applied', () => {
  const plan = validSevenDayPlan();
  plan.days[0].exercises[0].sets[0].targetWeight = 200; // aggressive, but nothing to compare against
  const result = validateWeeklyPlan(plan, baseContext());
  assert.equal(result.ok, true);
  assert.equal(result.verdicts.length, 0);
  assert.equal(result.clampedPlan.days[0].exercises[0].sets[0].targetWeight, 200);
});

test('missing days array entirely is a hard rejection, not a crash', () => {
  const result = validateWeeklyPlan({ notDays: [] }, baseContext());
  assert.equal(result.ok, false);
  assert.equal(result.clampedPlan, null);
});

test('null plan is a hard rejection, not a crash', () => {
  const result = validateWeeklyPlan(null, baseContext());
  assert.equal(result.ok, false);
});

// ---- validateReplanDays (Phase 3) ----

function replanDay(planDate, exercises) {
  return { planDate, title: 'Replanned', focus: null, exercises };
}

test('validateReplanDays: exact target date set passes clean', () => {
  const targetDates = ['2026-07-15', '2026-07-16'];
  const plan = {
    days: [replanDay('2026-07-15', [validExercise()]), replanDay('2026-07-16', [])],
    coachSummary: 'Adjusted.',
  };
  const result = validateReplanDays(plan, targetDates, baseContext());
  assert.equal(result.ok, true);
  assert.deepEqual(result.structuralViolations, []);
});

test('validateReplanDays: no daysPerWeek or 7-day expectation — a single target day is fine', () => {
  const result = validateReplanDays(
    { days: [replanDay('2026-07-15', [])], coachSummary: 'Rest day.' },
    ['2026-07-15'],
    baseContext()
  );
  assert.equal(result.ok, true);
});

test('validateReplanDays: missing a target date is rejected', () => {
  const result = validateReplanDays(
    { days: [replanDay('2026-07-15', [])], coachSummary: '' },
    ['2026-07-15', '2026-07-16'],
    baseContext()
  );
  assert.equal(result.ok, false);
  assert.ok(result.structuralViolations.some((v) => v.includes('missing replanned day for 2026-07-16')));
});

test('validateReplanDays: an extra day outside the target set is rejected', () => {
  const result = validateReplanDays(
    { days: [replanDay('2026-07-15', []), replanDay('2026-07-20', [])], coachSummary: '' },
    ['2026-07-15'],
    baseContext()
  );
  assert.equal(result.ok, false);
  assert.ok(result.structuralViolations.some((v) => v.includes('unexpected day 2026-07-20')));
});

test('validateReplanDays: duplicate planDate entries are rejected', () => {
  const result = validateReplanDays(
    { days: [replanDay('2026-07-15', []), replanDay('2026-07-15', [])], coachSummary: '' },
    ['2026-07-15'],
    baseContext()
  );
  assert.equal(result.ok, false);
  assert.ok(result.structuralViolations.some((v) => v.includes('duplicate planDate')));
});

test('validateReplanDays: reuses the same safety clamps as the weekly validator (unknown exerciseId)', () => {
  const plan = { days: [replanDay('2026-07-15', [{ ...validExercise(), exerciseId: 'made-up' }])], coachSummary: '' };
  const result = validateReplanDays(plan, ['2026-07-15'], baseContext());
  assert.equal(result.ok, false);
  assert.ok(result.structuralViolations.some((v) => v.includes('unknown exerciseId')));
});

test('validateReplanDays: reuses weight clamping, not rejection', () => {
  const plan = { days: [replanDay('2026-07-15', [validExercise()])], coachSummary: '' };
  plan.days[0].exercises[0].sets[0].targetWeight = 100;
  const context = baseContext({
    exerciseHistory: { 'barbell-bench-press': { occurrences: [{ allSetsHit: true, maxWeightKg: 60, targetReps: 8 }] } },
  });
  const result = validateReplanDays(plan, ['2026-07-15'], context);
  assert.equal(result.ok, true);
  assert.equal(result.verdicts.length, 1);
  assert.equal(result.clampedPlan.days[0].exercises[0].sets[0].targetWeight, 60 * MAX_WEEKLY_INCREASE_FACTOR);
});
