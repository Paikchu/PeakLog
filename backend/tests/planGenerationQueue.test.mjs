// Regression tests for the Issue #135 plan-generation queue.
//
// The two behaviours that broke in production were both invisible: PostgREST
// silently truncated the profile scan at max_rows, and a single slow user
// silently consumed the request budget for everyone behind them. Neither
// produced an error, so neither was observable without waiting a week. These
// tests exist to make both observable in a second.
//
// WHAT IS AND IS NOT COVERED HERE
// `_shared/planGenerationQueue.mjs` is driven against an in-memory fake of
// the PostgREST surface plus a JS MODEL of the four queue RPCs. The model is
// a model: it mirrors what claim/complete/fail/release do, it is not the SQL.
// It is therefore evidence about the MODULE's behaviour (does the worker
// refund an unstarted task? does one handler's exception reach another
// task?), and about the shape of the contract the module expects, but it is
// NOT evidence that the SQL implements that contract.
//
// The SQL side is covered two ways instead:
//   * planGenerationQueueMigration.test.mjs asserts the migration actually
//     contains the constructs that make the contract hold (FOR UPDATE SKIP
//     LOCKED, the fencing predicate on every report, the unique identity key,
//     deny-all RLS) and that its backoff constants match retryDelaySeconds().
//   * backend/tests/sql/plan_generation_queue_checks.sql executes the real
//     functions against a live database; it needs `supabase start` and is not
//     part of `node --test`.
//
// Run: node --test backend/tests/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  classifyDueProfiles,
  enqueueDueTasks,
  isInferenceTaskStale,
  isWeeklyTaskStale,
  MIN_TASK_BUDGET_MS,
  POSTGREST_MAX_ROWS,
  processQueueOnce,
  retryDelaySeconds,
  scanProfilePages,
} from '../supabase/functions/_shared/planGenerationQueue.mjs';

// A Sunday. 20:30 UTC is inside the weekly window (Sunday >= 20:00) but
// outside the inference window (21:00-22:59); 21:30 is inside both.
const SUNDAY_2030 = new Date('2026-07-26T20:30:00Z');
const SUNDAY_2130 = new Date('2026-07-26T21:30:00Z');
const NEXT_MONDAY = '2026-07-27';

const silentLogger = { log() {}, warn() {}, error() {} };

// MARK: - In-memory PostgREST fake

/**
 * Enough of the PostgREST builder surface for this module: from().select()
 * .order().limit().gt().eq().in().maybeSingle() and .upsert(). The builder is
 * thenable, so `await query` runs it — which is exactly how the module uses
 * it (it awaits the builder, never a terminal .execute()).
 *
 * Every read is recorded so the tests can assert on the SHAPE of the traffic,
 * not just the results: "did any single request ask for more rows than
 * PostgREST would return" is the question the original bug failed.
 */
function createFakeDb({ profiles = [], trainingPlans = [], queue = [], cursor = null } = {}) {
  const db = {
    profiles: [...profiles],
    training_plans: [...trainingPlans],
    plan_generation_queue: [...queue],
    plan_generation_enqueue_cursor: cursor ? [{ ...cursor }] : [{ id: 'singleton', last_user_id: null }],
  };
  const reads = [];
  const upserts = [];
  const rpcCalls = [];

  function matches(row, filters) {
    return filters.every(([op, column, value]) => {
      if (op === 'eq') return row[column] === value;
      if (op === 'gt') return row[column] > value;
      if (op === 'in') return value.includes(row[column]);
      throw new Error(`unsupported filter ${op}`);
    });
  }

  class Query {
    constructor(table) {
      this.table = table;
      this.filters = [];
      this.orderBy = null;
      this.limitN = null;
      this.single = false;
    }
    select(columns) { this.columns = columns; return this; }
    order(column, { ascending = true } = {}) { this.orderBy = { column, ascending }; return this; }
    limit(n) { this.limitN = n; return this; }
    gt(column, value) { this.filters.push(['gt', column, value]); return this; }
    eq(column, value) { this.filters.push(['eq', column, value]); return this; }
    in(column, values) { this.filters.push(['in', column, values]); return this; }
    maybeSingle() { this.single = true; return this; }
    run() {
      let rows = (db[this.table] ?? []).filter((row) => matches(row, this.filters));
      if (this.orderBy) {
        const { column, ascending } = this.orderBy;
        rows = [...rows].sort((a, b) =>
          (ascending ? 1 : -1) * String(a[column]).localeCompare(String(b[column])));
      }
      reads.push({ table: this.table, limit: this.limitN, filters: this.filters, returned: rows.length });
      if (this.limitN != null) rows = rows.slice(0, this.limitN);
      if (this.single) return { data: rows[0] ?? null, error: null };
      return { data: rows.map((row) => ({ ...row })), error: null };
    }
    then(onFulfilled, onRejected) {
      return Promise.resolve().then(() => this.run()).then(onFulfilled, onRejected);
    }
  }

  const client = {
    from(table) {
      const query = new Query(table);
      query.upsert = async (rows, { onConflict, ignoreDuplicates = false } = {}) => {
        const batch = Array.isArray(rows) ? rows : [rows];
        upserts.push({ table, count: batch.length, onConflict, ignoreDuplicates });
        const keyColumns = String(onConflict).split(',').map((c) => c.trim());
        for (const row of batch) {
          const key = keyColumns.map((c) => row[c]).join('|');
          const existing = (db[table] ?? []).find((r) => keyColumns.map((c) => r[c]).join('|') === key);
          if (existing) {
            // ignoreDuplicates => Prefer: resolution=ignore-duplicates =>
            // ON CONFLICT DO NOTHING. The whole idempotency story rests on
            // this, so the fake must not quietly "update instead".
            if (!ignoreDuplicates) Object.assign(existing, row);
            continue;
          }
          db[table].push({
            id: `${table}-${db[table].length + 1}`,
            status: 'pending',
            attempt_count: 0,
            max_attempts: 3,
            ...row,
          });
        }
        return { data: null, error: null };
      };
      return query;
    },
    async rpc(name, params) {
      rpcCalls.push({ name, params });
      const handler = db.__rpc?.[name];
      if (!handler) throw new Error(`unexpected rpc ${name}`);
      return handler(params);
    },
  };

  return { db, client, reads, upserts, rpcCalls };
}

function makeProfiles(count, timezone = 'UTC') {
  return Array.from({ length: count }, (_, i) => ({
    // Zero-padded so lexicographic order matches numeric order, which is what
    // the keyset cursor relies on.
    id: `user-${String(i).padStart(5, '0')}`,
    timezone,
  }));
}

// MARK: - Pagination / enqueue

test('scanProfilePages visits every profile past PostgREST max_rows, exactly once', async () => {
  const { client, reads } = createFakeDb({ profiles: makeProfiles(2500) });

  const seen = [];
  const scan = await scanProfilePages(client, (page) => { seen.push(...page.map((p) => p.id)); });

  assert.equal(scan.scanned, 2500);
  assert.equal(seen.length, 2500);
  assert.equal(new Set(seen).size, 2500, 'no profile may be visited twice');
  assert.equal(seen[0], 'user-00000');
  assert.equal(seen.at(-1), 'user-02499', 'the tail past row 1000 must be reached');
  assert.equal(scan.completedFullScan, true);
  for (const read of reads.filter((r) => r.table === 'profiles')) {
    assert.ok(read.limit <= POSTGREST_MAX_ROWS,
      `a page asked for ${read.limit} rows, which PostgREST would silently truncate`);
  }
});

test('enqueueDueTasks declares a task for all 2500 due users, not just the first 1000', async () => {
  const { client, db } = createFakeDb({ profiles: makeProfiles(2500) });

  const summary = await enqueueDueTasks(client, { now: SUNDAY_2030, logger: silentLogger });

  assert.equal(summary.scanned, 2500);
  assert.equal(summary.weeklyDeclared, 2500);
  assert.equal(summary.inferenceDeclared, 0, '20:30 is outside the inference window');
  assert.equal(summary.completedFullScan, true);
  assert.equal(db.plan_generation_queue.length, 2500);
  assert.ok(db.plan_generation_queue.some((t) => t.user_id === 'user-02499'),
    'the user past the max_rows ceiling must be enqueued — that is the bug');
  for (const task of db.plan_generation_queue) {
    assert.equal(task.kind, 'weekly');
    assert.equal(task.target_date, NEXT_MONDAY);
  }
});

test('enqueueDueTasks skips users who already have a plan for the target week', async () => {
  const { client, db } = createFakeDb({
    profiles: makeProfiles(3),
    trainingPlans: [{ user_id: 'user-00001', week_start_date: NEXT_MONDAY }],
  });

  const summary = await enqueueDueTasks(client, { now: SUNDAY_2030, logger: silentLogger });

  assert.equal(summary.weeklyDeclared, 2);
  assert.deepEqual(db.plan_generation_queue.map((t) => t.user_id), ['user-00000', 'user-00002']);
});

test('enqueueDueTasks is idempotent: four ticks inside the same window produce one task per user', async () => {
  const { client, db, upserts } = createFakeDb({ profiles: makeProfiles(50) });

  for (const tick of ['20:30', '21:30', '22:30', '23:30']) {
    const now = new Date(`2026-07-26T${tick}:00Z`);
    await enqueueDueTasks(client, { now, logger: silentLogger });
  }

  const weekly = db.plan_generation_queue.filter((t) => t.kind === 'weekly');
  assert.equal(weekly.length, 50, 'repeat ticks must not duplicate the weekly task');
  const identities = weekly.map((t) => `${t.kind}|${t.user_id}|${t.target_date}`);
  assert.equal(new Set(identities).size, 50);

  // 21:30 and 22:30 are also inside the inference window; 23:30 is not.
  const inference = db.plan_generation_queue.filter((t) => t.kind === 'inference');
  assert.equal(inference.length, 50, 'the two inference ticks collapse onto one task per user per local day');

  for (const upsert of upserts.filter((u) => u.table === 'plan_generation_queue')) {
    assert.equal(upsert.ignoreDuplicates, true, 'enqueue must be ON CONFLICT DO NOTHING, never an update');
    assert.equal(upsert.onConflict, 'kind,user_id,target_date');
  }
});

test('enqueueDueTasks never resurrects a task that already reached a terminal state', async () => {
  const { client, db } = createFakeDb({
    profiles: makeProfiles(2),
    queue: [
      { id: 'q1', kind: 'weekly', user_id: 'user-00000', target_date: NEXT_MONDAY, status: 'succeeded', attempt_count: 1, max_attempts: 3 },
      { id: 'q2', kind: 'weekly', user_id: 'user-00001', target_date: NEXT_MONDAY, status: 'failed', attempt_count: 3, max_attempts: 3 },
    ],
  });

  await enqueueDueTasks(client, { now: SUNDAY_2030, logger: silentLogger });

  assert.equal(db.plan_generation_queue.length, 2);
  assert.deepEqual(db.plan_generation_queue.map((t) => t.status), ['succeeded', 'failed']);
});

test('an interrupted enqueue persists a cursor, and the next tick resumes from it', async () => {
  const { client, db } = createFakeDb({ profiles: makeProfiles(300) });

  // deadlineMs already in the past => stop after the first page.
  const first = await enqueueDueTasks(client, {
    now: SUNDAY_2030, pageSize: 100, deadlineMs: Date.now() - 1, logger: silentLogger,
  });

  assert.equal(first.scanned, 100);
  assert.equal(first.budgetExhausted, true);
  assert.equal(first.completedFullScan, false);
  assert.equal(first.resumeFrom, 'user-00099');
  assert.equal(db.plan_generation_enqueue_cursor[0].last_user_id, 'user-00099');

  // The next tick must NOT restart at the beginning — that is precisely the
  // behaviour that starved the same tail every week.
  const second = await enqueueDueTasks(client, {
    now: SUNDAY_2030, pageSize: 100, deadlineMs: Date.now() - 1, logger: silentLogger,
  });
  assert.equal(second.resumedFrom, 'user-00099');
  assert.equal(second.resumeFrom, 'user-00199');

  const third = await enqueueDueTasks(client, { now: SUNDAY_2030, pageSize: 100, logger: silentLogger });
  assert.equal(third.resumedFrom, 'user-00199');
  assert.equal(third.completedFullScan, true);
  assert.equal(third.resumeFrom, null, 'a completed scan resets the cursor for the next cycle');
  assert.equal(db.plan_generation_queue.length, 300, 'every user is enqueued across the three ticks');
});

test('a cursor read failure restarts the scan rather than stopping it', async () => {
  const { client, db } = createFakeDb({ profiles: makeProfiles(5) });
  const inner = client.from;
  client.from = (table) => {
    if (table === 'plan_generation_enqueue_cursor') {
      const query = inner.call(client, table);
      const failing = { ...query, maybeSingle: () => Promise.resolve({ data: null, error: { message: 'boom' } }) };
      failing.select = () => failing;
      failing.eq = () => failing;
      failing.upsert = query.upsert;
      return failing;
    }
    return inner.call(client, table);
  };

  const summary = await enqueueDueTasks(client, { now: SUNDAY_2030, logger: silentLogger });
  assert.equal(summary.scanned, 5);
  assert.equal(db.plan_generation_queue.length, 5);
});

// MARK: - Window classification

test('classifyDueProfiles splits the two kinds of due work and normalizes timezones', () => {
  const profiles = [
    { id: 'utc', timezone: 'UTC' },
    { id: 'shanghai', timezone: 'Asia/Shanghai' },
    { id: 'corrupt', timezone: 'GMT+8' }, // rejected by resolveTimezone => UTC
  ];

  const at2030 = classifyDueProfiles(profiles, SUNDAY_2030);
  assert.deepEqual(at2030.weekly.map((c) => c.userId).sort(), ['corrupt', 'utc']);
  assert.deepEqual(at2030.inference, []);

  const at2130 = classifyDueProfiles(profiles, SUNDAY_2130);
  assert.deepEqual(at2130.weekly.map((c) => c.userId).sort(), ['corrupt', 'utc']);
  assert.deepEqual(at2130.inference.map((c) => c.userId).sort(), ['corrupt', 'utc']);
  assert.equal(at2130.weekly[0].targetDate, NEXT_MONDAY);
  assert.equal(at2130.inference[0].targetDate, '2026-07-26');
});

// MARK: - Pinned target date / staleness

test('a weekly task is stale exactly when C21 would refuse it', () => {
  // Enqueued Sunday for 2026-07-27; still fine at Sunday 23:59.
  assert.equal(isWeeklyTaskStale(NEXT_MONDAY, 'UTC', new Date('2026-07-26T23:59:00Z')), false);
  // Once local time is Monday, that Monday IS the current week: C21
  // ("refusing to install a plan for the current or a past week") applies.
  assert.equal(isWeeklyTaskStale(NEXT_MONDAY, 'UTC', new Date('2026-07-27T00:01:00Z')), true);
  assert.equal(isWeeklyTaskStale('2026-07-20', 'UTC', SUNDAY_2030), true);
});

test('an inference task is stale once the user local day has rolled over', () => {
  assert.equal(isInferenceTaskStale('2026-07-26', 'UTC', SUNDAY_2130), false);
  assert.equal(isInferenceTaskStale('2026-07-26', 'UTC', new Date('2026-07-27T00:30:00Z')), true);
  // Timezone-relative, not UTC-relative: 00:30 UTC is still the 26th in
  // New York, so the task there is not stale yet.
  assert.equal(isInferenceTaskStale('2026-07-26', 'America/New_York', new Date('2026-07-27T00:30:00Z')), false);
});

// MARK: - Backoff

test('retryDelaySeconds is exponential from 60s and capped at 1800s', () => {
  assert.deepEqual([1, 2, 3, 4, 5, 6].map(retryDelaySeconds), [60, 120, 240, 480, 960, 1800]);
  assert.equal(retryDelaySeconds(100), 1800, 'an uncapped exponential would outlive the four-hour window');
  assert.equal(retryDelaySeconds(0), 60, 'attempt numbers are clamped to >= 1');
  assert.equal(retryDelaySeconds(undefined), 60);
});

// MARK: - Worker
//
// Below this line the client carries a JS MODEL of the queue RPCs (see the
// header note). It is faithful about the properties the module depends on —
// a claim is atomic and hands out disjoint sets, a report only applies while
// the caller still holds the lease — and deliberately not about anything else.

function attachQueueModel(fake, { clock = { now: Date.now() } } = {}) {
  const { db } = fake;

  // The claim body below runs synchronously end to end, which is how it
  // models the SQL: `WITH ... FOR UPDATE SKIP LOCKED` + UPDATE is one atomic
  // statement, so no second claimer can observe a row between "selected" and
  // "marked running". Everything after it keys off status/locked_by, exactly
  // like the real predicates do.
  db.__rpc = {
    claim_plan_generation_tasks({ p_worker_id, p_limit, p_lease_seconds }) {
      if (!p_worker_id) throw new Error('p_worker_id is required');
      const limit = Math.min(Math.max(p_limit ?? 1, 1), 10);

      // Reclamation runs first, exactly as claim_plan_generation_tasks does.
      for (const task of db.plan_generation_queue) {
        if (task.status !== 'running') continue;
        if (task.lease_expires_at == null || task.lease_expires_at > clock.now) continue;
        task.status = task.attempt_count >= task.max_attempts ? 'failed' : 'pending';
        task.next_retry_at = clock.now + retryDelaySeconds(task.attempt_count) * 1000;
        task.locked_by = null;
        task.lease_expires_at = null;
        task.last_error = `lease expired without a report from worker ${task.locked_by ?? '<unknown>'}`;
      }

      const claimed = db.plan_generation_queue
        .filter((t) => t.status === 'pending' && (t.next_retry_at ?? 0) <= clock.now)
        .sort((a, b) => (a.next_retry_at ?? 0) - (b.next_retry_at ?? 0))
        .slice(0, limit);

      for (const task of claimed) {
        task.status = 'running';
        task.attempt_count += 1;
        task.locked_by = p_worker_id;
        task.lease_expires_at = clock.now + (p_lease_seconds ?? 300) * 1000;
        task.last_error = null;
      }
      return { data: claimed.map((t) => ({ ...t })), error: null };
    },

    complete_plan_generation_task({ p_task_id, p_worker_id, p_result }) {
      const task = db.plan_generation_queue.find((t) => t.id === p_task_id);
      if (!task || task.status !== 'running' || task.locked_by !== p_worker_id) {
        return { data: false, error: null };
      }
      task.status = 'succeeded';
      task.locked_by = null;
      task.lease_expires_at = null;
      task.last_error = null;
      task.result = p_result;
      return { data: true, error: null };
    },

    fail_plan_generation_task({ p_task_id, p_worker_id, p_error, p_retryable }) {
      const task = db.plan_generation_queue.find((t) => t.id === p_task_id);
      if (!task || task.status !== 'running' || task.locked_by !== p_worker_id) {
        return { data: false, error: null };
      }
      task.status = (p_retryable !== true || task.attempt_count >= task.max_attempts) ? 'failed' : 'pending';
      task.next_retry_at = clock.now + retryDelaySeconds(task.attempt_count) * 1000;
      task.locked_by = null;
      task.lease_expires_at = null;
      task.last_error = String(p_error ?? 'unspecified error').slice(0, 2000);
      return { data: true, error: null };
    },

    release_plan_generation_task({ p_task_id, p_worker_id }) {
      const task = db.plan_generation_queue.find((t) => t.id === p_task_id);
      if (!task || task.status !== 'running' || task.locked_by !== p_worker_id) {
        return { data: false, error: null };
      }
      task.status = 'pending';
      task.attempt_count = Math.max(task.attempt_count - 1, 0);
      task.next_retry_at = clock.now;
      task.locked_by = null;
      task.lease_expires_at = null;
      return { data: true, error: null };
    },
  };

  return { clock };
}

function pendingTasks(count, overrides = {}) {
  return Array.from({ length: count }, (_, i) => ({
    id: `task-${i}`,
    kind: 'weekly',
    user_id: `user-${i}`,
    target_date: NEXT_MONDAY,
    status: 'pending',
    attempt_count: 0,
    max_attempts: 3,
    next_retry_at: 0,
    ...overrides,
  }));
}

test('claiming goes through the RPC, never a client-side read-modify-write', async () => {
  const fake = createFakeDb({ queue: pendingTasks(1) });
  attachQueueModel(fake);

  await processQueueOnce(fake.client, {
    workerId: 'w1', limit: 1, handlers: { weekly: async () => ({ status: 'succeeded' }) }, logger: silentLogger,
  });

  assert.deepEqual(fake.rpcCalls.map((c) => c.name), [
    'claim_plan_generation_tasks', 'complete_plan_generation_task',
  ]);
  assert.equal(fake.reads.filter((r) => r.table === 'plan_generation_queue').length, 0,
    'two workers reading then writing would both claim the same row — that is why it is a SQL function');
  assert.equal(fake.rpcCalls[1].params.p_worker_id, 'w1', 'the report must carry the fencing token');
});

test('two workers claiming at once get disjoint task sets', async () => {
  const fake = createFakeDb({ queue: pendingTasks(6) });
  attachQueueModel(fake);

  const handler = async () => ({ status: 'succeeded' });
  const [a, b] = await Promise.all([
    processQueueOnce(fake.client, { workerId: 'w1', limit: 3, handlers: { weekly: handler }, logger: silentLogger }),
    processQueueOnce(fake.client, { workerId: 'w2', limit: 3, handlers: { weekly: handler }, logger: silentLogger }),
  ]);

  const idsA = a.processed.map((p) => p.taskId);
  const idsB = b.processed.map((p) => p.taskId);
  assert.equal(idsA.length, 3);
  assert.equal(idsB.length, 3);
  assert.equal(new Set([...idsA, ...idsB]).size, 6, 'no task may be handed to both workers');
  assert.equal(fake.db.plan_generation_queue.filter((t) => t.status === 'succeeded').length, 6);
});

test('one task failing does not touch the other tasks in the same batch', async () => {
  const fake = createFakeDb({ queue: pendingTasks(4) });
  attachQueueModel(fake);

  const handlers = {
    weekly: async (task) => {
      if (task.id === 'task-1') throw new Error('DeepSeek timed out');
      if (task.id === 'task-2') return { status: 'failed', retryable: true, error: 'validation failed' };
      return { status: 'succeeded', result: { status: 'installed' } };
    },
  };

  const summary = await processQueueOnce(fake.client, {
    workerId: 'w1', limit: 4, handlers, logger: silentLogger,
  });

  assert.equal(summary.claimed, 4);
  assert.deepEqual(summary.processed.map((p) => p.outcome), ['succeeded', 'failed', 'failed', 'succeeded']);
  // A thrown handler must be reported, not allowed to abort the loop — the
  // remaining tasks belong to OTHER users.
  assert.match(summary.processed[1].error, /DeepSeek timed out/);
  assert.equal(fake.db.plan_generation_queue.find((t) => t.id === 'task-3').status, 'succeeded');
  // Failures go back to pending with the attempt spent and the backoff applied.
  const failed = fake.db.plan_generation_queue.find((t) => t.id === 'task-1');
  assert.equal(failed.status, 'pending');
  assert.equal(failed.attempt_count, 1);
});

test('a task the request has no budget left for is released, not failed', async () => {
  const fake = createFakeDb({ queue: pendingTasks(2) });
  attachQueueModel(fake);

  let handled = 0;
  const summary = await processQueueOnce(fake.client, {
    workerId: 'w1',
    limit: 2,
    // Enough budget for the first task's check, not for the second.
    deadlineMs: Date.now() + MIN_TASK_BUDGET_MS + 50,
    handlers: {
      weekly: async () => { handled += 1; await new Promise((r) => setTimeout(r, 60)); return { status: 'succeeded' }; },
    },
    logger: silentLogger,
  });

  assert.equal(handled, 1);
  assert.deepEqual(summary.processed.map((p) => p.outcome), ['succeeded', 'released']);
  assert.equal(summary.released, 1);

  const released = fake.db.plan_generation_queue.find((t) => t.id === 'task-1');
  assert.equal(released.status, 'pending');
  assert.equal(released.attempt_count, 0,
    'nothing was tried, so the attempt must be refunded — otherwise an over-claiming worker walks every task to failed without one LLM call');
});

test('an unknown task kind fails terminally instead of blocking the FIFO head', async () => {
  const fake = createFakeDb({ queue: pendingTasks(1, { kind: 'from_the_future' }) });
  attachQueueModel(fake);

  const summary = await processQueueOnce(fake.client, {
    workerId: 'w1', handlers: { weekly: async () => ({ status: 'succeeded' }) }, logger: silentLogger,
  });

  assert.equal(summary.processed[0].outcome, 'failed');
  assert.equal(fake.rpcCalls.at(-1).params.p_retryable, false);
  assert.equal(fake.db.plan_generation_queue[0].status, 'failed');
});

test('retries back off and go terminal once attempts are exhausted', async () => {
  const clock = { now: 1_000_000 };
  const fake = createFakeDb({ queue: pendingTasks(1) });
  attachQueueModel(fake, { clock });

  const handlers = { weekly: async () => ({ status: 'failed', retryable: true, error: 'LLM call failed' }) };
  const task = () => fake.db.plan_generation_queue[0];
  const observed = [];

  for (let round = 0; round < 3; round += 1) {
    await processQueueOnce(fake.client, { workerId: `w${round}`, handlers, logger: silentLogger });
    observed.push({
      status: task().status,
      attempts: task().attempt_count,
      delaySeconds: (task().next_retry_at - clock.now) / 1000,
    });
    clock.now = task().next_retry_at; // jump to when it becomes due again
  }

  assert.deepEqual(observed, [
    { status: 'pending', attempts: 1, delaySeconds: 60 },
    { status: 'pending', attempts: 2, delaySeconds: 120 },
    { status: 'failed', attempts: 3, delaySeconds: 240 },
  ]);
});

test('a task is not claimable again until its backoff expires', async () => {
  const clock = { now: 1_000_000 };
  const fake = createFakeDb({ queue: pendingTasks(1) });
  attachQueueModel(fake, { clock });

  const failing = { weekly: async () => ({ status: 'failed', retryable: true, error: 'boom' }) };
  await processQueueOnce(fake.client, { workerId: 'w1', handlers: failing, logger: silentLogger });

  clock.now += 30_000; // still inside the 60s backoff
  const early = await processQueueOnce(fake.client, { workerId: 'w2', handlers: failing, logger: silentLogger });
  assert.equal(early.claimed, 0);

  clock.now += 31_000;
  const late = await processQueueOnce(fake.client, { workerId: 'w3', handlers: failing, logger: silentLogger });
  assert.equal(late.claimed, 1);
});

test('a lease that expires without a report is reclaimed for the next worker', async () => {
  const clock = { now: 1_000_000 };
  const fake = createFakeDb({ queue: pendingTasks(1) });
  attachQueueModel(fake, { clock });

  // A worker that was killed mid-generation (Edge Function timeout, deploy,
  // OOM) leaves exactly this: status='running', a lease, and no report ever.
  const row = fake.db.plan_generation_queue[0];
  Object.assign(row, {
    status: 'running', attempt_count: 1, locked_by: 'zombie',
    lease_expires_at: clock.now + 300_000, next_retry_at: 0,
  });

  const succeed = { weekly: async () => ({ status: 'succeeded' }) };

  clock.now += 299_000;
  const tooEarly = await processQueueOnce(fake.client, { workerId: 'w2', handlers: succeed, logger: silentLogger });
  assert.equal(tooEarly.claimed, 0, 'a live lease must never be stolen from underneath its owner');
  assert.equal(row.status, 'running');

  // Past the lease: reclaimed to pending. The attempt is NOT refunded — it
  // was genuinely spent, very likely on a paid LLM call — so a task that
  // keeps timing out walks to 'failed' instead of looping forever. It also
  // does not become claimable in the same tick: reclamation applies the
  // normal backoff.
  clock.now += 2_000;
  const reclaiming = await processQueueOnce(fake.client, { workerId: 'w2', handlers: succeed, logger: silentLogger });
  assert.equal(reclaiming.claimed, 0);
  assert.equal(row.status, 'pending');
  assert.equal(row.attempt_count, 1);
  assert.equal(row.next_retry_at, clock.now + 60_000);

  clock.now = row.next_retry_at;
  const reclaimed = await processQueueOnce(fake.client, { workerId: 'w2', handlers: succeed, logger: silentLogger });
  assert.equal(reclaimed.claimed, 1, 'the abandoned task must eventually reach another worker');
  assert.equal(row.status, 'succeeded');
});

test('a zombie report is rejected once the lease has moved on', async () => {
  const clock = { now: 1_000_000 };
  const fake = createFakeDb({ queue: pendingTasks(1) });
  attachQueueModel(fake, { clock });

  await processQueueOnce(fake.client, {
    workerId: 'w1', handlers: { weekly: async () => ({ status: 'succeeded' }) }, logger: silentLogger,
  });
  // The task is succeeded and unlocked; a late report from a stale worker id
  // must not apply to it.
  const late = await fake.client.rpc('fail_plan_generation_task', {
    p_task_id: 'task-0', p_worker_id: 'zombie', p_error: 'stale', p_retryable: true,
  });
  assert.equal(late.data, false);
  assert.equal(fake.db.plan_generation_queue[0].status, 'succeeded');
});
