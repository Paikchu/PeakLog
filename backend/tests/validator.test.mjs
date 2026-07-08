import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  validateWeeklyPlan,
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
