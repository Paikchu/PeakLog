import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migrationUrl = new URL('../supabase/migrations/20260711000017_cross_tenant_plan_integrity.sql', import.meta.url);

test('migration enforces tenant-consistent plan hierarchy and linked exercise sets', async () => {
  const sql = await readFile(migrationUrl, 'utf8');

  for (const relationship of [
    'FOREIGN KEY (plan_id, user_id)',
    'FOREIGN KEY (plan_day_id, plan_id, user_id)',
    'FOREIGN KEY (plan_exercise_id, plan_id, user_id)',
    'FOREIGN KEY (linked_exercise_set_id, user_id)',
  ]) {
    assert.match(sql, new RegExp(relationship.replace(/[()]/g, '\\$&')));
  }
  assert.match(sql, /SET linked_exercise_set_id = NULL/i, 'legacy malicious links must be neutralized before constraints');
});
