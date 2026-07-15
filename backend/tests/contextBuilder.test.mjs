import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  computeAdherence,
  buildExerciseHistory,
  summarizeEditEvents,
  projectGoalSpec,
  projectLibrary,
  buildContext,
  normalizeToKg,
  estimateOneRepMax,
  summarizeCurrentWeekDays,
  buildReplanContext,
} from '../supabase/functions/_shared/contextBuilder.mjs';

test('normalizeToKg passes kg through and converts lbs', () => {
  assert.equal(normalizeToKg(100, 'kg'), 100);
  assert.ok(Math.abs(normalizeToKg(220, 'lbs') - 99.79) < 0.01);
  assert.equal(normalizeToKg(null, 'kg'), null);
});

test('estimateOneRepMax: 1 rep is just the weight; higher reps push it up (Epley)', () => {
  assert.equal(estimateOneRepMax(100, 1), 100);
  assert.equal(estimateOneRepMax(100, 10), 100 * (1 + 10 / 30));
  assert.equal(estimateOneRepMax(null, 5), null);
  assert.equal(estimateOneRepMax(100, 0), null);
});

test('computeAdherence: empty plan set list has a null rate, not NaN or a crash', () => {
  const result = computeAdherence([]);
  assert.equal(result.total, 0);
  assert.equal(result.rate, null);
});

test('computeAdherence: counts sets with either completedAt or a linked set as done', () => {
  const result = computeAdherence([
    { completed_at: '2026-07-06T10:00:00Z', linked_exercise_set_id: null },
    { completed_at: null, linked_exercise_set_id: 'abc' },
    { completed_at: null, linked_exercise_set_id: null },
  ]);
  assert.equal(result.completed, 2);
  assert.equal(result.total, 3);
  assert.equal(result.rate, 2 / 3);
});

test('buildExerciseHistory: occurrences with no linked actual set are skipped', () => {
  const planExerciseRows = [{ id: 'pe1', exercise_id: 'bench', exercise_name: 'Bench', exercise_load_type: 'weighted' }];
  const planSetRows = [{ plan_exercise_id: 'pe1', linked_exercise_set_id: null, target_reps: 8 }];
  const history = buildExerciseHistory({ planExerciseRows, planSetRows, actualSetsById: {} });
  assert.equal(Object.keys(history).length, 0);
});

test('buildExerciseHistory: caller must pass oldest-week-first; occurrences come out most-recent-first', () => {
  // Two weeks for the same exercise: week 1 (older) missed, week 2 (newer) hit.
  const planExerciseRows = [
    { id: 'pe-week1', exercise_id: 'bench', exercise_name: 'Bench', exercise_load_type: 'weighted' },
    { id: 'pe-week2', exercise_id: 'bench', exercise_name: 'Bench', exercise_load_type: 'weighted' },
  ];
  const planSetRows = [
    { plan_exercise_id: 'pe-week1', linked_exercise_set_id: 'actual-week1', target_reps: 8 },
    { plan_exercise_id: 'pe-week2', linked_exercise_set_id: 'actual-week2', target_reps: 8 },
  ];
  const actualSetsById = {
    'actual-week1': { weight: 60, weight_unit: 'kg', reps: 6 }, // missed (6 < 8)
    'actual-week2': { weight: 62.5, weight_unit: 'kg', reps: 8 }, // hit
  };
  const history = buildExerciseHistory({ planExerciseRows, planSetRows, actualSetsById, equipmentByExerciseId: { bench: 'barbell' } });
  const occurrences = history.bench.occurrences;
  assert.equal(occurrences.length, 2);
  assert.equal(occurrences[0].allSetsHit, true, 'most recent (week 2) must come first');
  assert.equal(occurrences[0].maxWeightKg, 62.5);
  assert.equal(occurrences[1].allSetsHit, false, 'older (week 1) must come second');
  // The reference suggestion must be driven off the most-recent occurrence.
  assert.equal(history.bench.reference.action, 'increase_weight');
});

test('buildExerciseHistory: e1RMSeries is most-recent-first and skips nulls', () => {
  const planExerciseRows = [{ id: 'pe1', exercise_id: 'squat', exercise_name: 'Squat', exercise_load_type: 'weighted' }];
  const planSetRows = [{ plan_exercise_id: 'pe1', linked_exercise_set_id: 'actual1', target_reps: 5 }];
  const actualSetsById = { actual1: { weight: 100, weight_unit: 'kg', reps: 5 } };
  const history = buildExerciseHistory({ planExerciseRows, planSetRows, actualSetsById, equipmentByExerciseId: { squat: 'barbell' } });
  assert.equal(history.squat.e1RMSeries.length, 1);
  assert.equal(history.squat.e1RMSeries[0], 100 * (1 + 5 / 30));
});

test('buildExerciseHistory: unlinked exercise_id rows are skipped entirely (no crash)', () => {
  const planExerciseRows = [{ id: 'pe1', exercise_id: null, exercise_name: 'Freeform thing', exercise_load_type: 'weighted' }];
  const history = buildExerciseHistory({ planExerciseRows, planSetRows: [], actualSetsById: {} });
  assert.equal(Object.keys(history).length, 0);
});

test('summarizeEditEvents: counts by type and returns most-recent-first, capped', () => {
  const events = [
    { event_type: 'set_target_updated', exercise_name: 'A', occurred_at: '2026-07-01T00:00:00Z', payload: {} },
    { event_type: 'set_target_updated', exercise_name: 'A', occurred_at: '2026-07-03T00:00:00Z', payload: {} },
    { event_type: 'exercise_removed', exercise_name: 'B', occurred_at: '2026-07-02T00:00:00Z', payload: {} },
  ];
  const summary = summarizeEditEvents(events, { maxRecent: 2 });
  assert.equal(summary.totalCount, 3);
  assert.equal(summary.byType.set_target_updated, 2);
  assert.equal(summary.byType.exercise_removed, 1);
  assert.equal(summary.recent.length, 2, 'maxRecent must cap the returned list');
  assert.equal(summary.recent[0].occurredAt, '2026-07-03T00:00:00Z', 'must be most-recent-first');
});

test('projectGoalSpec: missing row falls back to a conservative default and flags isDefault', () => {
  const spec = projectGoalSpec(null);
  assert.equal(spec.isDefault, true);
  assert.equal(spec.objective, 'general');
  assert.equal(spec.daysPerWeek, 3);
});

test('projectGoalSpec: real row passes through with isDefault false', () => {
  const spec = projectGoalSpec({
    objective: 'strength', days_per_week: 5, session_minutes: 75,
    equipment: ['barbell'], focus_areas: ['chest'], experience: 'advanced', note: 'hi',
  });
  assert.equal(spec.isDefault, false);
  assert.equal(spec.daysPerWeek, 5);
  assert.deepEqual(spec.equipment, ['barbell']);
});

test('projectLibrary: merges seed library with this user\'s custom exercises, custom ids get the "custom-" prefix', () => {
  const library = projectLibrary(
    [{ id: 'bench', nameEN: 'Bench', nameZH: '卧推', muscleGroup: 'chest', equipment: 'barbell', loadType: 'weighted' }],
    [{ id: 'abc', name_en: 'Sled Push', name_zh: '雪橇推', muscle_group: 'legs', equipment: 'other', load_type: 'weighted' }]
  );
  assert.equal(library.length, 2);
  assert.equal(library[1].id, 'custom-abc');
  assert.equal(library[1].nameEN, 'Sled Push');
});

test('buildContext: isColdStart is true only when there is neither adherence data nor exercise history', () => {
  const cold = buildContext({
    goalSpecRow: null, weightUnit: 'kg', language: 'en',
    planExerciseRows: [], planSetRows: [], actualSetsById: {},
    editEventRows: [], libraryExercises: [], customExercises: [],
    weekStartDate: '2026-07-13', libraryVersion: '1',
  });
  assert.equal(cold.isColdStart, true);

  const warm = buildContext({
    goalSpecRow: null, weightUnit: 'kg', language: 'en',
    planExerciseRows: [{ id: 'pe1', exercise_id: 'bench', exercise_name: 'Bench', exercise_load_type: 'weighted' }],
    planSetRows: [{ plan_exercise_id: 'pe1', linked_exercise_set_id: 'a1', target_reps: 8, completed_at: '2026-07-06T00:00:00Z' }],
    actualSetsById: { a1: { weight: 60, weight_unit: 'kg', reps: 8 } },
    editEventRows: [], libraryExercises: [{ id: 'bench', nameEN: 'Bench', nameZH: '卧推', muscleGroup: 'chest', equipment: 'barbell', loadType: 'weighted' }],
    customExercises: [], weekStartDate: '2026-07-13', libraryVersion: '1',
  });
  assert.equal(warm.isColdStart, false);
  assert.equal(warm.adherence.total, 1);
  assert.ok(warm.exerciseHistory.bench);
});

test('buildContext: propagates weekStartDate and weightUnit unchanged', () => {
  const context = buildContext({
    goalSpecRow: null, weightUnit: 'lbs', language: 'zh-Hans',
    planExerciseRows: [], planSetRows: [], actualSetsById: {},
    editEventRows: [], libraryExercises: [], customExercises: [],
    weekStartDate: '2026-07-20', libraryVersion: null,
  });
  assert.equal(context.weekStartDate, '2026-07-20');
  assert.equal(context.weightUnit, 'lbs');
  assert.equal(context.language, 'zh-Hans');
});

// ---- summarizeCurrentWeekDays / buildReplanContext (Phase 3) ----

test('summarizeCurrentWeekDays: orders by day_index and flags hasCompletedSets per day', () => {
  const dayRows = [
    { id: 'd2', day_index: 1, plan_date: '2026-07-08', title: 'Day B', focus: null },
    { id: 'd1', day_index: 0, plan_date: '2026-07-07', title: 'Day A', focus: 'push' },
  ];
  const exerciseRows = [
    { id: 'e1', plan_day_id: 'd1', exercise_name: 'Bench', exercise_id: 'bench' },
    { id: 'e2', plan_day_id: 'd2', exercise_name: 'Squat', exercise_id: 'squat' },
  ];
  const setRows = [
    { plan_exercise_id: 'e1', target_reps: 8, completed_at: '2026-07-07T10:00:00Z', linked_exercise_set_id: null },
    { plan_exercise_id: 'e2', target_reps: 5, completed_at: null, linked_exercise_set_id: null },
  ];

  const overview = summarizeCurrentWeekDays({ dayRows, exerciseRows, setRows });
  assert.equal(overview.length, 2);
  assert.equal(overview[0].planDate, '2026-07-07', 'must be ordered by day_index, not array order');
  assert.equal(overview[0].hasCompletedSets, true);
  assert.equal(overview[1].planDate, '2026-07-08');
  assert.equal(overview[1].hasCompletedSets, false);
  assert.equal(overview[0].exercises[0].completedCount, 1);
  assert.equal(overview[0].exercises[0].totalCount, 1);
});

test('summarizeCurrentWeekDays: a rest day with no exercises has hasCompletedSets false, not a crash', () => {
  const overview = summarizeCurrentWeekDays({
    dayRows: [{ id: 'd1', day_index: 0, plan_date: '2026-07-07', title: 'Rest', focus: null }],
    exerciseRows: [],
    setRows: [],
  });
  assert.equal(overview[0].exercises.length, 0);
  assert.equal(overview[0].hasCompletedSets, false);
});

test('summarizeCurrentWeekDays: completed cardio protects the day from replan', () => {
  const overview = summarizeCurrentWeekDays({
    dayRows: [{ id: 'd1', day_index: 0, plan_date: '2026-07-07', title: 'Cardio', focus: null }],
    exerciseRows: [{
      id: 'c1',
      plan_day_id: 'd1',
      exercise_name: 'Cycling',
      exercise_id: null,
      item_type: 'cardio',
      cardio_activity_type: 'cycling',
      target_duration_minutes: 30,
      target_distance_km: 10,
      target_rpe: 6,
      cardio_completed_at: '2026-07-07T10:00:00Z',
      linked_cardio_workout_id: 'run-1',
    }],
    setRows: [],
  });

  assert.equal(overview[0].hasCompletedSets, true);
  assert.equal(overview[0].exercises[0].itemType, 'cardio');
  assert.equal(overview[0].exercises[0].cardioActivityType, 'cycling');
  assert.equal(overview[0].exercises[0].completedCount, 1);
  assert.equal(overview[0].exercises[0].totalCount, 1);
});

test('buildReplanContext: includes base facts plus a replan object with signal/targetDates/currentWeekOverview', () => {
  const context = buildReplanContext({
    goalSpecRow: null, weightUnit: 'kg', language: 'en',
    planExerciseRows: [], planSetRows: [], actualSetsById: {},
    editEventRows: [], libraryExercises: [], customExercises: [],
    weekStartDate: '2026-07-06', libraryVersion: '1',
    currentWeekDayRows: [{ id: 'd1', day_index: 0, plan_date: '2026-07-08', title: 'Day', focus: null }],
    currentWeekExerciseRows: [],
    currentWeekSetRows: [],
    targetDates: ['2026-07-09'],
    signal: 'time_limited',
  });
  assert.equal(context.weekStartDate, '2026-07-06', 'replan context uses the CURRENT week, not next week');
  assert.equal(context.replan.signal, 'time_limited');
  assert.deepEqual(context.replan.targetDates, ['2026-07-09']);
  assert.equal(context.replan.currentWeekOverview.length, 1);
  assert.equal(context.replan.currentWeekOverview[0].planDate, '2026-07-08');
});

test('buildReplanContext: signal defaults to null (behavioral-inference trigger has no signal)', () => {
  const context = buildReplanContext({
    goalSpecRow: null, weightUnit: 'kg', language: 'en',
    planExerciseRows: [], planSetRows: [], actualSetsById: {},
    editEventRows: [], libraryExercises: [], customExercises: [],
    weekStartDate: '2026-07-06', libraryVersion: '1',
    currentWeekDayRows: [], currentWeekExerciseRows: [], currentWeekSetRows: [],
    targetDates: ['2026-07-09'],
  });
  assert.equal(context.replan.signal, null);
});
