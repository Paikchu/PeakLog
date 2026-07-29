// SQL-side guards for the Issue #135 plan-generation queue.
//
// planGenerationQueue.test.mjs drives the JS module against a MODEL of the
// queue RPCs, which proves things about the module but nothing about the
// migration. This file covers the other half: that the migration actually
// contains the constructs the model assumes, and that the security posture
// this project has been burned by before (SECURITY NOTE in
// 20260708000013 — new public functions pick up an EXECUTE grant for `anon`
// that `REVOKE ... FROM PUBLIC` does not remove) is applied to every new
// function here.
//
// It is static analysis of SQL text, deliberately: executing the real
// functions needs a live Postgres, which lives in
// backend/tests/sql/plan_generation_queue_checks.sql and is not part of
// `node --test`.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { retryDelaySeconds } from '../supabase/functions/_shared/planGenerationQueue.mjs';

const queueMigrationUrl = new URL('../supabase/migrations/20260729101500_plan_generation_queue.sql', import.meta.url);
const cronMigrationUrl = new URL('../supabase/migrations/20260729102000_switch_generation_cron_to_queue.sql', import.meta.url);
const functionUrl = new URL('../supabase/functions/generate-weekly-plan/index.ts', import.meta.url);

const NEW_FUNCTIONS = [
  'plan_generation_retry_delay',
  'reclaim_expired_plan_generation_leases',
  'claim_plan_generation_tasks',
  'complete_plan_generation_task',
  'fail_plan_generation_task',
  'release_plan_generation_task',
  'plan_generation_queue_health',
  'purge_plan_generation_queue',
];

test('the queue table carries every column the retry/lease protocol needs', async () => {
  const sql = (await readFile(queueMigrationUrl, 'utf8')).toLowerCase();

  for (const column of [
    'kind', 'user_id', 'target_date', 'status', 'attempt_count', 'max_attempts',
    'next_retry_at', 'locked_by', 'lease_expires_at', 'last_error', 'created_at', 'updated_at',
  ]) {
    assert.match(sql, new RegExp(`\\b${column}\\b`), `missing ${column}`);
  }

  assert.match(sql, /status[^,]*check\s*\(status\s+in\s*\('pending',\s*'running',\s*'succeeded',\s*'failed'\)\)/s,
    'the four states the metrics/alerting acceptance criterion is written against');
  assert.match(sql, /kind[^,]*check\s*\(kind\s+in\s*\('weekly',\s*'inference'\)\)/s);
});

test('the idempotency key makes a second task for the same user+week impossible', async () => {
  const sql = (await readFile(queueMigrationUrl, 'utf8')).toLowerCase();
  assert.match(sql, /unique\s*\(\s*kind\s*,\s*user_id\s*,\s*target_date\s*\)/,
    'without this, two enqueue ticks could both install a plan for the same week');
});

test('the queue is service_role-only: RLS on, zero policies, grants revoked', async () => {
  const sql = await readFile(queueMigrationUrl, 'utf8');

  for (const table of ['plan_generation_queue', 'plan_generation_enqueue_cursor']) {
    assert.match(sql, new RegExp(`alter table ${table} enable row level security`, 'i'));
    assert.match(sql, new RegExp(`revoke all on table ${table} from anon`, 'i'));
    assert.match(sql, new RegExp(`revoke all on table ${table} from authenticated`, 'i'));
    assert.match(sql, new RegExp(`grant all on table ${table} to service_role`, 'i'));
  }

  // RLS is default-deny, so the ABSENCE of policies is the access rule. A
  // future migration adding one here would silently open a table that holds
  // lease tokens and lets its writer spend LLM budget on any user_id.
  assert.doesNotMatch(sql, /create\s+policy/i,
    'plan_generation_queue is infrastructure, not user data — it must have no policies at all');
  assert.doesNotMatch(sql, /disable\s+row\s+level\s+security/i);
});

test('every new function is revoked from anon and authenticated, then granted to service_role', async () => {
  const sql = await readFile(queueMigrationUrl, 'utf8');

  for (const fn of NEW_FUNCTIONS) {
    assert.match(sql, new RegExp(`create or replace function public\\.${fn}\\b`, 'i'), `${fn} is not defined here`);
    for (const role of ['anon', 'authenticated']) {
      assert.match(sql, new RegExp(`revoke all on function public\\.${fn}\\([^)]*\\) from ${role}`, 'i'),
        `${fn} is still reachable by ${role} — see the SECURITY NOTE in 20260708000013`);
    }
    assert.match(sql, new RegExp(`grant execute on function public\\.${fn}\\([^)]*\\) to service_role`, 'i'));
  }
});

test('the state-changing RPCs also check auth.role() as defense in depth', async () => {
  const sql = await readFile(queueMigrationUrl, 'utf8');
  const guarded = [
    'claim_plan_generation_tasks',
    'complete_plan_generation_task',
    'fail_plan_generation_task',
    'release_plan_generation_task',
  ];
  for (const fn of guarded) {
    const body = sql.slice(sql.indexOf(`FUNCTION public.${fn}`));
    const end = body.indexOf('END $$;');
    assert.match(body.slice(0, end),
      new RegExp(`auth\\.role\\(\\) is distinct from 'service_role'[\\s\\S]{0,200}raise exception`, 'i'),
      `${fn} must refuse a non-service_role caller even if a future migration gets its grants wrong`);
  }
});

test('claiming is atomic: FOR UPDATE SKIP LOCKED, one statement, attempt spent at claim time', async () => {
  const sql = await readFile(queueMigrationUrl, 'utf8');
  const claim = sql.slice(sql.indexOf('FUNCTION public.claim_plan_generation_tasks'));
  const body = claim.slice(0, claim.indexOf('END $$;'));

  assert.match(body, /for\s+update\s+skip\s+locked/i,
    'two workers doing a client-side read-modify-write would both claim the same row');
  assert.match(body, /order\s+by\s+q\.next_retry_at,\s*q\.created_at/i, 'FIFO fairness — position in an array used to decide who got served');
  assert.match(body, /attempt_count\s*=\s*t\.attempt_count\s*\+\s*1/i,
    'a worker killed mid-generation never reports, so the attempt must be spent at claim time');
  assert.match(body, /lease_expires_at\s*=\s*now\(\)\s*\+\s*make_interval/i);
  assert.match(body, /least\(greatest\(coalesce\(p_limit, 1\), 1\), 10\)/i,
    'an unbounded p_limit would rebuild the original O(users)-per-request bug on top of the queue');
});

test('every completion report is fenced by the lease token', async () => {
  const sql = await readFile(queueMigrationUrl, 'utf8');

  for (const fn of ['complete_plan_generation_task', 'fail_plan_generation_task', 'release_plan_generation_task']) {
    const start = sql.indexOf(`FUNCTION public.${fn}`);
    const body = sql.slice(start, sql.indexOf('END $$;', start));
    assert.match(body, /status\s*=\s*'running'/i, `${fn} must only apply to a task that is actually running`);
    assert.match(body, /locked_by\s*=\s*p_worker_id/i,
      `${fn} without the fence lets a zombie worker clobber the state of whoever took over its task`);
    assert.match(body, /return v_count = 1;/i, `${fn} must tell the caller whether its report landed`);
  }

  // release() is the "claimed but never started" path: the attempt must come
  // back or an over-claiming worker burns tasks to 'failed' with no LLM call.
  const release = sql.slice(sql.indexOf('FUNCTION public.release_plan_generation_task'));
  assert.match(release.slice(0, release.indexOf('END $$;')),
    /attempt_count\s*=\s*greatest\(t\.attempt_count\s*-\s*1,\s*0\)/i);
});

test('expired leases are reclaimed without refunding the attempt', async () => {
  const sql = await readFile(queueMigrationUrl, 'utf8');
  const fn = sql.slice(sql.indexOf('FUNCTION public.reclaim_expired_plan_generation_leases'));
  const body = fn.slice(0, fn.indexOf('END $$;'));

  assert.match(body, /status\s*=\s*'running'/i);
  assert.match(body, /lease_expires_at\s*<\s*now\(\)/i);
  assert.match(body, /for\s+update\s+skip\s+locked/i);
  assert.match(body, /when t\.attempt_count >= t\.max_attempts then 'failed' else 'pending' end/i,
    'a task that keeps timing out must walk to failed, not loop forever');
  assert.doesNotMatch(body, /attempt_count\s*=\s*0/i);
  // Reclamation runs at the head of every claim, so a crashed worker's task
  // is recoverable on the next tick without a separate janitor.
  assert.match(sql, /perform public\.reclaim_expired_plan_generation_leases\(\);/i);
});

test('the SQL backoff and retryDelaySeconds() agree on base and cap', async () => {
  const sql = await readFile(queueMigrationUrl, 'utf8');
  const start = sql.indexOf('FUNCTION public.plan_generation_retry_delay');
  const body = sql.slice(start, sql.indexOf('$$;', start));

  assert.match(body, /least\(\s*\d+\s*\*\s*power\(2,/,
    'plan_generation_retry_delay must keep the least(base * 2^(n-1), cap) shape');

  const base = Number(body.match(/least\(\s*(\d+)\s*\*\s*power\(2,/)[1]);
  // The cap is the largest literal in a function whose only other numbers are
  // the base, the exponent base and the attempt clamps.
  const cap = Math.max(...[...body.matchAll(/\b(\d+)\b/g)].map((m) => Number(m[1])));
  assert.equal(retryDelaySeconds(1), base, 'first retry delay diverged from the SQL');
  assert.equal(retryDelaySeconds(2), base * 2);
  assert.equal(retryDelaySeconds(3), base * 4);
  assert.equal(retryDelaySeconds(99), cap, 'the cap diverged from the SQL');
});

test('metrics and alerting exist and do not become an RLS bypass', async () => {
  const sql = await readFile(queueMigrationUrl, 'utf8');

  assert.match(sql, /create or replace view public\.plan_generation_queue_metrics\s*\n?\s*with \(security_invoker = true\)/i,
    'a security_definer view over a deny-all table would hand any grantee a readable window onto it');
  assert.match(sql, /group by q\.kind, q\.status/i, 'per-kind, per-status counts');
  assert.match(sql, /revoke all on public\.plan_generation_queue_metrics from anon/i);

  const health = sql.slice(sql.indexOf('FUNCTION public.plan_generation_queue_health'));
  const body = health.slice(0, health.indexOf('END $$;'));
  for (const status of ['pending', 'running', 'succeeded', 'failed']) {
    assert.match(body, new RegExp(`filter \\(where status = '${status}'\\)`, 'i'), `no ${status} metric`);
  }
  assert.match(body, /'oldest_pending_due_lag_seconds'/, 'queue lag is the backlog alert signal');
  assert.match(body, /'alert',/);
  assert.match(body, /'alert_reasons',/);
  assert.match(body, /p_lag_alert_seconds/);
});

test('the cron migration switches traffic to the queue and leaves older migrations alone', async () => {
  const sql = await readFile(cronMigrationUrl, 'utf8');

  assert.match(sql, /cron\.unschedule\('generate-weekly-plan-hourly'\)/,
    'the whole-fleet-in-one-request job must stop');
  assert.match(sql, /'\{"action":"enqueue"\}'::jsonb/);
  assert.match(sql, /'\{"action":"work","limit":\d+\}'::jsonb/);
  assert.match(sql, /purge_plan_generation_queue/);

  // Concurrency comes from more worker REQUESTS (SKIP LOCKED keeps them
  // disjoint), never from a bigger batch inside one request.
  const workerLimit = Number(sql.match(/"action":"work","limit":(\d+)/)[1]);
  assert.ok(workerLimit <= 5, `a worker request claiming ${workerLimit} tasks is not a bounded request any more`);
  assert.match(sql, /FOR v_worker IN 1\.\.\d+ LOOP/);

  // Re-runnable against a fresh `supabase db reset`, where cron state differs.
  assert.match(sql, /if exists \(select 1 from cron\.job where jobname/i);
  assert.doesNotMatch(sql, /drop\s+(table|function)/i, 'this migration must only touch cron scheduling');
});

test('the cron entrypoint is enqueue-only and no longer reads profiles unpaginated', async () => {
  const source = await readFile(functionUrl, 'utf8');

  assert.match(source, /import \{[\s\S]*enqueueDueTasks[\s\S]*processQueueOnce[\s\S]*\} from "\.\.\/_shared\/planGenerationQueue\.mjs"/);
  // The literal `{}` the pre-#135 cron entry posts must enqueue, not sweep.
  assert.match(source, /function resolveAction[\s\S]*?return "enqueue";\n\}/);
  // Every profile read goes through the keyset paginator now; the bare
  // select is what PostgREST silently truncated at max_rows.
  assert.doesNotMatch(source, /from\("profiles"\)\s*\.select\("id, timezone"\)/,
    'an unpaginated whole-table profile read is the Issue #135 bug');
  assert.equal((source.match(/scanProfilePages\(/g) ?? []).length, 2,
    'both remaining fleet scans (selectDueUsers, runInferenceSweep) must be paginated');
  // The issue explicitly rules out swapping the serial loop for an unbounded
  // Promise.all over users.
  assert.doesNotMatch(source, /Promise\.all\(\s*targetUserIds/);
  // A retry must target the week the task was DECLARED for, not "next Monday
  // from whenever the retry happens".
  assert.match(source, /weekStartDate: task\.target_date/);
});
