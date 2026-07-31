// SQL-side guards for the Issue #148 server-side deletion log.
//
// Static analysis of the migration text, deliberately: the behavioural half —
// does the trigger actually fire on a cascade, does RLS actually hide another
// user's tombstones — needs a live Postgres and lives in
// backend/tests/sql/record_deletions_checks.sql, outside `node --test`.
//
// What is checked here is the set of properties whose violation is silent. A
// missing trigger on one of the five tables does not fail anything: deletions
// in that table simply stop propagating, and the symptom ("a record I deleted
// on my phone came back on my iPad") surfaces days later on someone else's
// device. Same for an accidental INSERT policy, which would let a client forge
// a tombstone and delete data everywhere.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const tableMigrationUrl = new URL('../supabase/migrations/20260731090000_record_deletions.sql', import.meta.url);
const cronMigrationUrl = new URL('../supabase/migrations/20260731090500_schedule_record_deletion_purge.sql', import.meta.url);

/** The five tables the iOS client syncs records for. */
const SYNCED_TABLES = [
  'workout_sessions',
  'exercises',
  'exercise_sets',
  'running_workouts',
  'custom_exercises',
];

test('the tombstone table carries the four columns the protocol is written against', async () => {
  const sql = (await readFile(tableMigrationUrl, 'utf8')).toLowerCase();

  assert.match(sql, /create table record_deletions\s*\(/);
  for (const column of ['id uuid', 'user_id uuid', 'table_name text', 'deleted_at timestamptz']) {
    assert.match(sql, new RegExp(column.replace(/\s+/, '\\s+')), `missing column: ${column}`);
  }

  // The natural key, not a surrogate one. This is what makes a retried DELETE
  // idempotent without a separate unique constraint, and it is the conflict
  // target the trigger's ON CONFLICT names.
  assert.match(sql, /primary key\s*\(\s*user_id\s*,\s*table_name\s*,\s*id\s*\)/,
    'the (user_id, table_name, id) key is what makes re-tombstoning a no-op');

  // Server clock. A client-supplied deleted_at would let one device's clock
  // skew move another device's pull cursor past a deletion it never saw.
  assert.match(sql, /deleted_at timestamptz not null default now\(\)/);
});

test('table_name is constrained to exactly the tables the client dispatches on', async () => {
  const sql = (await readFile(tableMigrationUrl, 'utf8')).toLowerCase();
  const check = sql.match(/table_name text not null check \(table_name in \(([^)]*)\)\)/s);
  assert.ok(check, 'table_name must carry a CHECK constraint');

  const named = [...check[1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]).sort();
  assert.deepEqual(named, [...SYNCED_TABLES].sort(),
    'a tombstone naming a table the client does not know about is a silent no-op on every device');
});

test('clients may read their own tombstones and nothing else — no write policy at all', async () => {
  const sql = await readFile(tableMigrationUrl, 'utf8');

  assert.match(sql, /ALTER TABLE record_deletions ENABLE ROW LEVEL SECURITY/);

  const policies = [...sql.matchAll(/CREATE POLICY\s+"([^"]+)"\s+ON record_deletions\s+FOR (\w+)/g)];
  assert.equal(policies.length, 1, `expected exactly one policy, got ${policies.map((p) => p[1]).join(', ')}`);
  assert.equal(policies[0][2], 'SELECT',
    'a forged tombstone deletes data on every device the user owns; an erasable one resurrects a deleted record');
  assert.match(sql, /FOR SELECT USING \(user_id = auth\.uid\(\)\)/);
});

test('every synced table gets the AFTER DELETE trigger', async () => {
  const sql = await readFile(tableMigrationUrl, 'utf8');

  for (const table of SYNCED_TABLES) {
    assert.match(
      sql,
      new RegExp(`CREATE TRIGGER ${table}_record_deletion\\s+AFTER DELETE ON ${table}\\s+FOR EACH ROW EXECUTE FUNCTION public\\.record_deletion_tombstone\\(\\)`),
      `${table} has no deletion trigger — its deletions would stop propagating silently`,
    );
  }

  // FOR EACH ROW, not FOR EACH STATEMENT: OLD is per row, and the cascade
  // coverage this whole design rests on is per row.
  assert.equal((sql.match(/FOR EACH ROW EXECUTE FUNCTION public\.record_deletion_tombstone\(\)/g) || []).length,
    SYNCED_TABLES.length);
});

test('the trigger function is SECURITY DEFINER with a pinned search_path, and idempotent', async () => {
  const sql = await readFile(tableMigrationUrl, 'utf8');

  const fn = sql.match(/CREATE OR REPLACE FUNCTION public\.record_deletion_tombstone\(\)[\s\S]*?AS \$\$[\s\S]*?END \$\$;/);
  assert.ok(fn, 'record_deletion_tombstone must exist');

  // SECURITY DEFINER is what lets it write to a table with no INSERT policy —
  // i.e. what makes "a tombstone exists" equivalent to "a row really was
  // deleted" rather than "someone asked for one".
  assert.match(fn[0], /SECURITY DEFINER/);
  assert.match(fn[0], /SET search_path = public, pg_temp/);
  assert.match(fn[0], /ON CONFLICT \(user_id, table_name, id\) DO NOTHING/,
    'a re-delete must keep the original deleted_at, not push the tombstone\'s expiry forward');
  assert.match(fn[0], /VALUES \(OLD\.id, OLD\.user_id, TG_TABLE_NAME\)/);
});

test('purge_record_deletions is service_role-only', async () => {
  const sql = await readFile(tableMigrationUrl, 'utf8');

  // The SECURITY NOTE in 20260708000013: a new public-schema function picks up
  // an EXECUTE grant for `anon` that REVOKE ... FROM PUBLIC does not remove.
  // Reachable unauthenticated, this one erases every tombstone in the project
  // and resurrects every deleted record on every device.
  for (const role of ['PUBLIC', 'anon', 'authenticated']) {
    assert.match(sql, new RegExp(`REVOKE ALL ON FUNCTION public\\.purge_record_deletions\\(interval\\) FROM ${role};`),
      `purge_record_deletions is still callable by ${role}`);
  }
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\.purge_record_deletions\(interval\) TO service_role;/);

  for (const role of ['PUBLIC', 'anon', 'authenticated']) {
    assert.match(sql, new RegExp(`REVOKE ALL ON FUNCTION public\\.record_deletion_tombstone\\(\\) FROM ${role};`),
      `record_deletion_tombstone is still callable by ${role} — a definer function that forges tombstones`);
  }
});

test('retention is 180 days and also collects tombstones of deleted accounts', async () => {
  const sql = await readFile(tableMigrationUrl, 'utf8');

  // The window IS the supported offline period: past it a returning device can
  // no longer be told about deletions it missed.
  assert.match(sql, /p_retain interval DEFAULT interval '180 days'/);
  assert.match(sql, /deleted_at < now\(\) - p_retain/);

  // There is no FK to auth.users (an insert during the account-deletion cascade
  // would fail and take account deletion with it), so orphans are swept here
  // instead. Both halves have to be true together.
  assert.doesNotMatch(sql, /user_id uuid NOT NULL REFERENCES auth\.users/,
    'an FK here breaks account deletion: the trigger inserts during the cascade, after the parent row is gone');
  assert.match(sql, /NOT EXISTS \(\s*SELECT 1 FROM auth\.users u WHERE u\.id = record_deletions\.user_id\s*\)/,
    'without the FK, deleted accounts leave tombstones nothing else collects');
});

test('the retention sweep is scheduled, in its own migration', async () => {
  const cron = await readFile(cronMigrationUrl, 'utf8');

  assert.match(cron, /cron\.schedule\(\s*'record-deletions-purge'/);
  assert.match(cron, /select public\.purge_record_deletions\(\);/);
  // Re-runnable against a branch database or a fresh `supabase db reset`.
  assert.match(cron, /IF EXISTS \(SELECT 1 FROM cron\.job WHERE jobname = 'record-deletions-purge'\)/);

  // Creating the table is inert; starting to delete tombstones is not. Keeping
  // them apart is what makes the retention policy independently revertible.
  const table = await readFile(tableMigrationUrl, 'utf8');
  assert.doesNotMatch(table, /cron\.schedule/,
    'the table migration must stay inert — no traffic changes');
});
