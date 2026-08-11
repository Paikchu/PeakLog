import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const migrationUrl = new URL(
  '../supabase/migrations/20260811093000_relax_cardio_plan_target.sql',
  import.meta.url
);

test('cardio plan targets accept duration, distance, or both', async () => {
  const sql = (await readFile(migrationUrl, 'utf8')).toLowerCase();

  // Replaces the payload check in place; nothing else about the table moves.
  assert.match(sql, /drop\s+constraint\s+if\s+exists\s+training_plan_exercises_cardio_payload_check/);
  assert.match(sql, /add\s+constraint\s+training_plan_exercises_cardio_payload_check/);

  // The point of the migration: at least one target, positive when present.
  assert.match(sql, /target_duration_minutes\s+is\s+not\s+null\s+or\s+target_distance_km\s+is\s+not\s+null/);
  assert.match(sql, /target_duration_minutes\s+is\s+null\s+or\s+target_duration_minutes\s*>\s*0/);
  assert.match(sql, /target_distance_km\s+is\s+null\s+or\s+target_distance_km\s*>\s*0/);
  // The old unconditional `AND target_duration_minutes > 0` is what made a
  // distance-only target impossible — it must not survive anywhere.
  assert.doesNotMatch(sql, /and\s+target_duration_minutes\s*>\s*0/);

  // Everything the old predicate guarded is still guarded.
  assert.match(sql, /item_type\s*=\s*'strength'[\s\S]+cardio_activity_type\s+is\s+null/);
  assert.match(sql, /cardio_activity_type\s+in\s*\(\s*'running',\s*'cycling',\s*'elliptical',\s*'stair_climber'\s*\)/);
  assert.match(sql, /cardio_activity_type\s+in\s*\(\s*'running',\s*'cycling'\s*\)\s+or\s+target_distance_km\s+is\s+null/);
  assert.match(sql, /target_rpe\s+is\s+null\s+or\s+target_rpe\s+between\s+1\s+and\s+10/);

  // Widening only: no data rewrite, no ownership or RLS change.
  assert.doesNotMatch(sql, /disable\s+row\s+level\s+security/);
  assert.doesNotMatch(sql, /\bupdate\s+training_plan_exercises\b/);
  assert.doesNotMatch(sql, /\bdrop\s+column\b/);
});
