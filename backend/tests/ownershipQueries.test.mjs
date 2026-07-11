import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchOwnedActualSets } from '../supabase/functions/_shared/ownershipQueries.mjs';

function clientReturning(rows) {
  const calls = [];
  const query = {
    select(columns) { calls.push(['select', columns]); return this; },
    in(column, values) { calls.push(['in', column, values]); return this; },
    eq(column, value) { calls.push(['eq', column, value]); return Promise.resolve({ data: rows, error: null }); },
  };
  return { client: { from(table) { calls.push(['from', table]); return query; } }, calls };
}

test('fetchOwnedActualSets scopes service-role reads to the current user', async () => {
  const { client, calls } = clientReturning([
    { id: 'victim-set', user_id: 'victim', weight: 200 },
  ]);

  await fetchOwnedActualSets(client, 'attacker', ['victim-set']);

  assert.deepEqual(calls, [
    ['from', 'exercise_sets'],
    ['select', '*'],
    ['in', 'id', ['victim-set']],
    ['eq', 'user_id', 'attacker'],
  ]);
});

test('fetchOwnedActualSets returns no rows for an empty link list', async () => {
  const { client, calls } = clientReturning([]);
  const rows = await fetchOwnedActualSets(client, 'attacker', []);
  assert.deepEqual(rows, []);
  assert.deepEqual(calls, []);
});

test('fetchOwnedActualSets excludes a malicious historical cross-tenant association from context inputs', async () => {
  const { client } = clientReturning([
    { id: 'attacker-set', user_id: 'attacker', weight: 60 },
    { id: 'victim-set', user_id: 'victim', weight: 200 },
  ]);

  const rows = await fetchOwnedActualSets(client, 'attacker', ['attacker-set', 'victim-set']);

  assert.deepEqual(rows.map((row) => row.id), ['attacker-set']);
});
