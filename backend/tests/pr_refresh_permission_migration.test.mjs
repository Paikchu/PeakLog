import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migrationURL = new URL('../supabase/migrations/20260711100944_lock_pr_refresh_helpers.sql', import.meta.url);

test('PR refresh helpers are not executable through the public Data API', async () => {
  const sql = await readFile(migrationURL, 'utf8');
  for (const helper of ['refresh_exercise_prs_for_user(uuid)', 'recompute_user_stats_for_user(uuid)']) {
    for (const role of ['PUBLIC', 'anon', 'authenticated']) {
      assert.match(sql, new RegExp(`REVOKE ALL ON FUNCTION ${helper.replace(/[()]/g, '\\$&')} FROM ${role};`));
    }
    assert.match(sql, new RegExp(`GRANT EXECUTE ON FUNCTION ${helper.replace(/[()]/g, '\\$&')} TO service_role;`));
  }
});
