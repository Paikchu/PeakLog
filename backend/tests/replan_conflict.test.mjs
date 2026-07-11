import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const functionURL = new URL('../supabase/functions/generate-weekly-plan/index.ts', import.meta.url);

test('replan stops on optimistic-lock conflict instead of replaying stale generated days', async () => {
  const source = await readFile(functionURL, 'utf8');
  const body = source.slice(source.indexOf('let installResult = await admin.rpc("replan_plan_days"'), source.indexOf('if (installResult.error)'));
  assert.doesNotMatch(body, /select\("revision"\)/);
  assert.doesNotMatch(body, /p_expected_revision: freshPlan\.revision/);
  assert.match(body, /status: "conflict"/);
});
