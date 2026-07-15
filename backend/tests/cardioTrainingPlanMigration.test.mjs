import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const migrationUrl = new URL('../supabase/migrations/20260715145641_add_cardio_training_plan.sql', import.meta.url);

test('cardio migration is additive, constrained, and ownership-safe', async () => {
  const sql = (await readFile(migrationUrl, 'utf8')).toLowerCase();

  for (const column of [
    'item_type',
    'cardio_activity_type',
    'target_duration_minutes',
    'target_distance_km',
    'target_rpe',
    'cardio_completed_at',
    'linked_cardio_workout_id',
    'activity_type',
    'rpe',
  ]) {
    assert.match(sql, new RegExp(`\\b${column}\\b`), `missing ${column}`);
  }

  assert.match(sql, /item_type[^;]+default\s+'strength'/s);
  assert.match(sql, /activity_type[^;]+default\s+'running'/s);
  assert.match(sql, /alter\s+column\s+distance_km\s+drop\s+not\s+null/);
  assert.match(sql, /distance_km\s+is\s+null\s+or\s+distance_km\s*>\s*0/);
  assert.match(sql, /target_duration_minutes\s*>\s*0/);
  assert.match(sql, /target_rpe\s+between\s+1\s+and\s+10/);
  assert.match(sql, /unique\s*\(\s*id\s*,\s*user_id\s*\)/);
  assert.match(sql, /foreign\s+key\s*\(\s*linked_cardio_workout_id\s*,\s*user_id\s*\)/);
  assert.match(sql, /references\s+running_workouts\s*\(\s*id\s*,\s*user_id\s*\)/);
  assert.doesNotMatch(sql, /disable\s+row\s+level\s+security/);
  for (const functionName of ['install_generated_plan', 'replan_plan_days']) {
    assert.match(sql, new RegExp(`create\\s+or\\s+replace\\s+function\\s+${functionName}`));
    assert.match(sql, new RegExp(`revoke\\s+all\\s+on\\s+function\\s+${functionName}[^;]+from\\s+anon`));
  }
  assert.match(sql, /item_type,\s*cardio_activity_type,\s*target_duration_minutes,\s*target_distance_km,\s*target_rpe/s);
  assert.match(sql, /e\.cardio_completed_at\s+is\s+not\s+null\s+or\s+e\.linked_cardio_workout_id\s+is\s+not\s+null/);
});
