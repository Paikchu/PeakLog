import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const functionUrl = new URL('../supabase/functions/generate-weekly-plan/index.ts', import.meta.url);

test('ownership query helper import resolves from the function entrypoint to the shared sibling directory', async () => {
  const source = await readFile(functionUrl, 'utf8');
  assert.match(source, /from "\.\.\/_shared\/ownershipQueries\.mjs";/);
  assert.doesNotMatch(source, /from "\.\/_shared\/ownershipQueries\.mjs";/);
});

test('all shared modules resolve from the function entrypoint to the shared sibling directory', async () => {
  const source = await readFile(functionUrl, 'utf8');
  for (const moduleName of [
    'contextBuilder',
    'validator',
    'llm',
    'prompt',
    'exerciseLibrary',
    'ownershipQueries',
  ]) {
    assert.match(source, new RegExp(`from "\\.\\.\\/_shared\\/${moduleName}\\.mjs";`));
    assert.doesNotMatch(source, new RegExp(`from "\\.\\/_shared\\/${moduleName}\\.mjs";`));
  }
});

test('per-user inference reads explicitly scope every plan hierarchy table by user_id', async () => {
  const source = await readFile(functionUrl, 'utf8');
  const inferenceGate = source.slice(source.indexOf('async function inferenceGateOpen'), source.indexOf('// MARK: - Weekly generation'));

  for (const table of ['training_plan_days', 'training_plan_exercises', 'training_plan_sets']) {
    const query = inferenceGate.match(new RegExp(`from\\("${table}"\\)[\\s\\S]*?(?=;|\\n\\s*const )`))?.[0] ?? '';
    assert.match(query, /\.eq\("user_id", userId\)/, `${table} must be tenant-scoped under service role`);
  }
});
