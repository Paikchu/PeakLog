import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const functionUrl = new URL('../supabase/functions/generate-weekly-plan/index.ts', import.meta.url);

test('weekly, replan, and fallback payloads clear cardio RPE', async () => {
  const source = await readFile(functionUrl, 'utf8');
  for (const field of [
    'itemType: exercise.itemType',
    'cardioActivityType: exercise.cardioActivityType',
    'targetDurationMinutes: exercise.targetDurationMinutes',
    'targetDistanceKm: exercise.targetDistanceKm',
  ]) {
    assert.equal(source.split(field).length - 1, 2, `${field} must be mapped by install and replan`);
  }
  assert.ok(source.includes('itemType: exercise.item_type'));
  assert.ok(source.includes('cardioActivityType: exercise.cardio_activity_type'));
  assert.equal(source.split('targetRPE: null').length - 1, 3);
  assert.ok(!source.includes('targetRPE: exercise.targetRPE'));
  assert.ok(!source.includes('targetRPE: exercise.target_rpe'));
});

test('missed-day inference includes completed cardio', async () => {
  const source = await readFile(functionUrl, 'utf8');
  assert.match(source, /cardio_completed_at\.not\.is\.null,linked_cardio_workout_id\.not\.is\.null/);
});
