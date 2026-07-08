import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  computeReferenceWeight,
  lbsToKg,
  kgToDisplay,
  BARBELL_STEP_KG,
  DUMBBELL_STEP_KG,
  DELOAD_FACTOR,
} from '../supabase/functions/_shared/referenceWeight.mjs';

test('no history -> hold, no suggestion', () => {
  const result = computeReferenceWeight({ loadType: 'weighted', equipment: 'barbell', recentOccurrences: [] });
  assert.equal(result.action, 'hold');
  assert.equal(result.suggestedWeightKg, null);
});

test('all sets hit on barbell -> +2.5kg', () => {
  const result = computeReferenceWeight({
    loadType: 'weighted',
    equipment: 'barbell',
    recentOccurrences: [{ allSetsHit: true, maxWeightKg: 60, targetReps: 8 }],
  });
  assert.equal(result.action, 'increase_weight');
  assert.equal(result.suggestedWeightKg, 60 + BARBELL_STEP_KG);
});

test('all sets hit on dumbbell -> +2kg (smaller increment)', () => {
  const result = computeReferenceWeight({
    loadType: 'weighted',
    equipment: 'dumbbell',
    recentOccurrences: [{ allSetsHit: true, maxWeightKg: 20, targetReps: 10 }],
  });
  assert.equal(result.action, 'increase_weight');
  assert.equal(result.suggestedWeightKg, 20 + DUMBBELL_STEP_KG);
});

test('kettlebell uses the dumbbell-sized step too', () => {
  const result = computeReferenceWeight({
    loadType: 'weighted',
    equipment: 'kettlebell',
    recentOccurrences: [{ allSetsHit: true, maxWeightKg: 16, targetReps: 12 }],
  });
  assert.equal(result.suggestedWeightKg, 16 + DUMBBELL_STEP_KG);
});

test('missed once -> hold at same weight (no deload yet)', () => {
  const result = computeReferenceWeight({
    loadType: 'weighted',
    equipment: 'barbell',
    recentOccurrences: [
      { allSetsHit: false, maxWeightKg: 100, targetReps: 5 },
      { allSetsHit: true, maxWeightKg: 97.5, targetReps: 5 },
    ],
  });
  assert.equal(result.action, 'hold');
  assert.equal(result.suggestedWeightKg, 100);
});

test('missed two in a row -> deload 10%, rounded to nearest 0.5kg', () => {
  const result = computeReferenceWeight({
    loadType: 'weighted',
    equipment: 'barbell',
    recentOccurrences: [
      { allSetsHit: false, maxWeightKg: 100, targetReps: 5 },
      { allSetsHit: false, maxWeightKg: 100, targetReps: 5 },
    ],
  });
  assert.equal(result.action, 'deload');
  assert.equal(result.suggestedWeightKg, Math.round(100 * DELOAD_FACTOR * 2) / 2);
});

test('bodyweight: all sets hit -> increase reps, never weight', () => {
  const result = computeReferenceWeight({
    loadType: 'bodyweight',
    equipment: 'bodyweight',
    recentOccurrences: [{ allSetsHit: true, maxWeightKg: null, targetReps: 8 }],
  });
  assert.equal(result.action, 'increase_reps');
  assert.equal(result.suggestedWeightKg, null);
  assert.equal(result.suggestedReps, 9); // <10 reps -> +1
});

test('bodyweight: high rep target hit -> bigger rep bump', () => {
  const result = computeReferenceWeight({
    loadType: 'bodyweight',
    equipment: 'bodyweight',
    recentOccurrences: [{ allSetsHit: true, maxWeightKg: null, targetReps: 12 }],
  });
  assert.equal(result.suggestedReps, 14); // >=10 reps -> +2
});

test('bodyweight: missed -> hold reps, never suggests a weight', () => {
  const result = computeReferenceWeight({
    loadType: 'bodyweight',
    equipment: 'bodyweight',
    recentOccurrences: [{ allSetsHit: false, maxWeightKg: null, targetReps: 8 }],
  });
  assert.equal(result.action, 'hold');
  assert.equal(result.suggestedWeightKg, null);
  assert.equal(result.suggestedReps, 8);
});

test('unit conversion round-trips lbs -> kg -> lbs', () => {
  const kg = lbsToKg(220);
  assert.ok(Math.abs(kg - 99.79) < 0.01);
  const backToLbs = kgToDisplay(kg, 'lbs');
  assert.ok(Math.abs(backToLbs - 220) < 0.001);
});

test('kgToDisplay is a no-op for kg preference', () => {
  assert.equal(kgToDisplay(80, 'kg'), 80);
});

test('kgToDisplay(null) is null, not a crash', () => {
  assert.equal(kgToDisplay(null, 'lbs'), null);
});
