// Queue plumbing for generate-weekly-plan (Issue #135): the paginated
// profile scan, the enqueue pass built on top of it, and the bounded worker
// loop.
//
// Deliberately a .mjs module with no Deno globals, like llm.mjs and
// generationWindow.mjs — the two decisions that used to be untestable
// (who gets picked up, and what happens when one user blows the request
// budget) are exactly the ones that broke in production, so they belong
// somewhere `node --test` can reach. index.ts keeps the I/O-heavy per-user
// pipeline and injects it here as handlers.
//
// The Supabase client is passed in rather than imported so the tests can
// drive both paths against an in-memory stub; every call this module makes
// goes through the plain PostgREST builder surface (from/select/eq/gt/order/
// limit/upsert/maybeSingle and rpc), never anything Deno-specific.

import {
  isGenerationWindowOpen,
  isInferenceWindowOpen,
  localDateString,
  nextMondayString,
  thisMondayString,
  resolveTimezone,
} from "./generationWindow.mjs";

export const QUEUE_TABLE = "plan_generation_queue";
export const CURSOR_TABLE = "plan_generation_enqueue_cursor";
export const CURSOR_ID = "singleton";

// PostgREST truncates every response at max_rows (backend/supabase/config.toml
// = 1000) WITHOUT reporting that it did so — that silent truncation is the
// root of half this issue. Paging at 500 keeps every request provably under
// the ceiling, so a short page genuinely means end-of-table rather than
// "you hit the cap".
export const PROFILE_PAGE_SIZE = 500;
export const POSTGREST_MAX_ROWS = 1000;

// Existing-plan lookups are batched per page, but a single
// `.in('user_id', [...500 uuids])` becomes a ~19KB query string on a GET,
// which is well into the territory where an intermediate proxy starts
// rejecting URLs. Chunking at 100 keeps each URL around 4KB.
const IN_FILTER_CHUNK = 100;

// Upsert batch size for queue rows. Unlike the GET above this travels in a
// request body, so the limit is statement size rather than URL length; 200
// keeps one page's worth of inserts to a handful of round trips.
const UPSERT_CHUNK = 200;

/**
 * Retry backoff, mirroring plan_generation_retry_delay() in
 * 20260729101500_plan_generation_queue.sql: 60s * 2^(attempt-1), capped at
 * 1800s. Duplicated in JS on purpose — the SQL is authoritative for what
 * actually happens, this copy exists so the schedule can be asserted in a
 * unit test instead of only being observable by waiting for a live retry.
 * A divergence between the two is a test failure
 * (backend/tests/planGenerationQueue.test.mjs asserts both against the same
 * table of expectations, and re-derives the SQL's own constants from the
 * migration source).
 */
export function retryDelaySeconds(attemptCount) {
  const attempt = Math.max(Number(attemptCount) || 1, 1);
  return Math.min(60 * Math.pow(2, attempt - 1), 1800);
}

function chunk(items, size) {
  const out = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

// MARK: - Profile pagination

/**
 * Walk `profiles` in keyset order, handing each page to `onPage`.
 *
 * Keyset (`WHERE id > cursor ORDER BY id`), not OFFSET: profile ids are
 * immutable, so a position stays valid across ticks and across concurrent
 * inserts, and re-reading page N never costs a scan of pages 1..N-1.
 *
 * Every caller in this codebase that reads the whole profile table goes
 * through here. That is the point: the original bug was a bare
 * `.select("id, timezone")` with no range at all, which PostgREST silently
 * truncated at max_rows so user #1001 was invisible rather than merely late.
 * A single paginator means there is exactly one place that has to be right.
 *
 * Stops when a short page proves end-of-table, when `onPage` returns
 * `{ stop: true }`, or when `deadlineMs` passes — the caller distinguishes
 * those via the returned `completedFullScan` / `budgetExhausted`.
 *
 * @param {object} client - Supabase service-role client
 * @param {(profiles: Array<{id: string, timezone: string|null}>) => Promise<{stop?: boolean}|void>} onPage
 * @param {object} [options]
 * @param {string|null} [options.startAfter] - keyset cursor; null = from the start
 * @param {number} [options.pageSize]
 * @param {number|null} [options.deadlineMs] - epoch ms; null = no budget cap
 */
export async function scanProfilePages(client, onPage, {
  startAfter = null,
  pageSize = PROFILE_PAGE_SIZE,
  deadlineMs = null,
} = {}) {
  const effectivePageSize = Math.min(Math.max(Math.trunc(pageSize) || 1, 1), POSTGREST_MAX_ROWS);

  let cursor = startAfter;
  let scanned = 0;
  let pages = 0;
  let completedFullScan = false;
  let budgetExhausted = false;
  let stoppedByCaller = false;

  for (;;) {
    let query = client
      .from("profiles")
      .select("id, timezone")
      .order("id", { ascending: true })
      .limit(effectivePageSize);
    if (cursor) query = query.gt("id", cursor);

    // deno-lint-ignore no-await-in-loop -- pagination is inherently serial:
    // the next page's cursor is the previous page's last id.
    const { data, error } = await query;
    if (error) throw error;

    const profiles = data ?? [];
    pages += 1;
    scanned += profiles.length;

    if (profiles.length > 0) {
      // deno-lint-ignore no-await-in-loop
      const verdict = await onPage(profiles);
      cursor = profiles[profiles.length - 1].id;
      if (verdict?.stop === true) {
        stoppedByCaller = true;
        break;
      }
    }

    // A short page can only mean end-of-table: effectivePageSize is provably
    // below PostgREST's max_rows, so it is never the cap talking.
    if (profiles.length < effectivePageSize) {
      completedFullScan = true;
      break;
    }

    if (deadlineMs != null && Date.now() >= deadlineMs) {
      budgetExhausted = true;
      break;
    }
  }

  return { scanned, pages, cursor, completedFullScan, budgetExhausted, stoppedByCaller };
}

// MARK: - Enqueue (cron path)

/**
 * Scan profiles page by page and declare a queue task for every user whose
 * local window is currently open. Makes no LLM calls and installs nothing —
 * the entire point is that this finishes fast and predictably regardless of
 * how many users exist.
 *
 * Two window predicates, two task kinds, one scan: a user can legitimately
 * be due for both (the weekly window is Sunday >= 20:00, the inference
 * window is 21:00–22:59 daily, so they overlap on Sunday evenings), and the
 * unique key keeps those as two independent tasks that retry independently.
 *
 * `deadlineMs` is the wall-clock instant this must stop by. On hitting it we
 * persist the cursor and return with completedFullScan=false; the next cron
 * tick resumes from the same profile id. That is the durable-cursor half of
 * the fix — before, an interrupted sweep simply lost everything after the
 * point of interruption, every time, always the same tail.
 *
 * @param {object} client - Supabase service-role client
 * @param {object} [options]
 * @param {Date}   [options.now]
 * @param {number} [options.pageSize]
 * @param {number|null} [options.deadlineMs] - epoch ms; null = no budget cap
 * @param {object} [options.logger]
 */
export async function enqueueDueTasks(client, {
  now = new Date(),
  pageSize = PROFILE_PAGE_SIZE,
  deadlineMs = null,
  logger = console,
} = {}) {
  const startedFromCursor = await readEnqueueCursor(client, logger);

  // "Declared", not "inserted": duplicates are dropped by the unique key
  // inside Postgres and PostgREST does not report which rows survived, so
  // these count the tasks this run asserted should exist. The interesting
  // number for "is anyone being missed" is scanned vs. completedFullScan.
  let weeklyDeclared = 0;
  let inferenceDeclared = 0;

  const scan = await scanProfilePages(client, async (profiles) => {
    const due = classifyDueProfiles(profiles, now);
    const counts = await enqueueClassifiedTasks(client, due, logger);
    weeklyDeclared += counts.weekly;
    inferenceDeclared += counts.inference;
  }, { startAfter: startedFromCursor, pageSize, deadlineMs });

  if (scan.budgetExhausted) {
    logger.warn?.(
      `enqueueDueTasks: request budget exhausted after ${scan.scanned} profiles; ` +
      `persisting cursor ${scan.cursor} for the next tick to resume from`
    );
  }

  // A completed scan resets the cursor to NULL so the next cycle starts from
  // the beginning; an interrupted one persists where it stopped.
  const resumeFrom = scan.completedFullScan ? null : scan.cursor;
  await writeEnqueueCursor(client, resumeFrom, { resetCycle: scan.completedFullScan, logger });

  return {
    scanned: scan.scanned,
    pages: scan.pages,
    weeklyDeclared,
    inferenceDeclared,
    completedFullScan: scan.completedFullScan,
    budgetExhausted: scan.budgetExhausted,
    resumedFrom: startedFromCursor,
    resumeFrom,
  };
}

/**
 * Split a page of profiles into the two kinds of due work. Pure — no I/O —
 * so the window logic is testable without a client.
 *
 * Timezones are normalized through resolveTimezone at this boundary
 * (generationWindow.mjs documents why: a single malformed profiles.timezone
 * used to be able to throw deeper in the pipeline and abort the whole sweep).
 */
export function classifyDueProfiles(profiles, now) {
  const weekly = [];
  const inference = [];
  for (const profile of profiles) {
    const timezone = resolveTimezone(profile.timezone);
    if (isGenerationWindowOpen(timezone, now)) {
      weekly.push({ userId: profile.id, targetDate: nextMondayString(timezone, now) });
    }
    if (isInferenceWindowOpen(timezone, now)) {
      // The expensive "did this user actually miss a session today" gate is
      // NOT evaluated here. It costs five queries per user and would make
      // enqueue's cost per profile unbounded again; the worker runs it, where
      // it is one bounded task's own budget. Enqueue only decides "this user's
      // clock says it is worth looking", and the unique key collapses the two
      // hourly ticks of the window into a single task.
      inference.push({ userId: profile.id, targetDate: localDateString(timezone, now) });
    }
  }
  return { weekly, inference };
}

/**
 * Skip weekly candidates that already have a plan for their target week, then
 * insert the rest with ON CONFLICT DO NOTHING.
 *
 * The pre-check is batched by (chunk of user ids) x (distinct target weeks) —
 * at most two distinct Mondays exist across all timezones at any instant. The
 * old code issued one `maybeSingle()` per profile, so the pre-check alone was
 * O(users) round trips inside the same request that then had to do the actual
 * generating.
 *
 * The check is an optimisation, not the safety net: the worker re-checks
 * before installing, and install_generated_plan raises unique_violation
 * regardless of what any caller believed. Enqueuing a task that turns out to
 * be redundant is harmless; it completes as a skip.
 */
async function enqueueClassifiedTasks(client, due, logger) {
  const rows = [];

  if (due.weekly.length > 0) {
    const existing = await fetchExistingPlanKeys(client, due.weekly);
    for (const candidate of due.weekly) {
      if (existing.has(`${candidate.userId}|${candidate.targetDate}`)) continue;
      rows.push({ kind: "weekly", user_id: candidate.userId, target_date: candidate.targetDate });
    }
  }

  for (const candidate of due.inference) {
    rows.push({ kind: "inference", user_id: candidate.userId, target_date: candidate.targetDate });
  }

  let weekly = 0;
  let inference = 0;
  for (const batch of chunk(rows, UPSERT_CHUNK)) {
    // ignoreDuplicates => `Prefer: resolution=ignore-duplicates` => ON
    // CONFLICT DO NOTHING against plan_generation_queue_identity. This is the
    // idempotency guarantee: four hourly ticks inside the same Sunday window,
    // or two overlapping enqueue runs, converge on exactly one task per
    // (kind, user, date) — and never resurrect one that already succeeded or
    // exhausted its attempts.
    // deno-lint-ignore no-await-in-loop
    const { error } = await client
      .from(QUEUE_TABLE)
      .upsert(batch, { onConflict: "kind,user_id,target_date", ignoreDuplicates: true });
    if (error) throw error;
    for (const row of batch) {
      if (row.kind === "weekly") weekly += 1;
      else inference += 1;
    }
  }

  if (rows.length > 0) {
    logger.log?.(`enqueueDueTasks: declared ${weekly} weekly + ${inference} inference task(s) for this page`);
  }
  return { weekly, inference };
}

async function fetchExistingPlanKeys(client, candidates) {
  const keys = new Set();
  const weeks = [...new Set(candidates.map((c) => c.targetDate))];
  for (const idBatch of chunk(candidates.map((c) => c.userId), IN_FILTER_CHUNK)) {
    // deno-lint-ignore no-await-in-loop
    const { data, error } = await client
      .from("training_plans")
      .select("user_id, week_start_date")
      .in("user_id", idBatch)
      .in("week_start_date", weeks);
    if (error) throw error;
    for (const row of data ?? []) keys.add(`${row.user_id}|${row.week_start_date}`);
  }
  return keys;
}

async function readEnqueueCursor(client, logger) {
  const { data, error } = await client
    .from(CURSOR_TABLE)
    .select("last_user_id")
    .eq("id", CURSOR_ID)
    .maybeSingle();
  if (error) {
    // A missing/unreadable cursor must not stop the sweep — restarting the
    // scan from the beginning is always CORRECT (enqueue is idempotent), just
    // potentially wasteful. Failing closed here would recreate the outage the
    // cursor exists to prevent.
    logger.error?.("enqueueDueTasks: cursor read failed, restarting scan from the beginning", error);
    return null;
  }
  return data?.last_user_id ?? null;
}

async function writeEnqueueCursor(client, lastUserId, { resetCycle, logger }) {
  const payload = { id: CURSOR_ID, last_user_id: lastUserId, updated_at: new Date().toISOString() };
  if (resetCycle) payload.cycle_started_at = new Date().toISOString();
  const { error } = await client.from(CURSOR_TABLE).upsert(payload, { onConflict: "id" });
  // Also non-fatal: the tasks for every page already scanned are committed,
  // so the worst case of a lost cursor write is that the next tick rescans
  // ground it has already covered and inserts nothing.
  if (error) logger.error?.("enqueueDueTasks: cursor write failed", error);
}

// MARK: - Staleness
//
// `target_date` is pinned at enqueue time so a delayed retry cannot drift
// onto a different week/day (see the column comment in the migration). These
// two predicates are what turns that pinning into an actual guard, and they
// are pure so the calendar edge cases are unit-testable rather than only
// observable once a week in production.

/**
 * A weekly task is stale once its target Monday is no longer strictly in the
 * future for that user. install_generated_plan enforces exactly this itself
 * (C21: "refusing to install a plan for the current or a past week"), so
 * without this check a task enqueued at Sunday 23:55 and retried at Monday
 * 00:05 would burn all three attempts collecting the same check_violation.
 * Detecting it here turns those into one clean terminal outcome.
 */
export function isWeeklyTaskStale(targetDate, timezone, now) {
  return String(targetDate) <= thisMondayString(timezone, now);
}

/**
 * An inference task is stale once the user's local calendar day has moved
 * past the day the sweep observed. Redistributing "today's" missed volume
 * into the remaining days is meaningless a day later — the days it would
 * have redistributed into are themselves now in the past.
 */
export function isInferenceTaskStale(targetDate, timezone, now) {
  return String(targetDate) !== localDateString(timezone, now);
}

// MARK: - Worker (claim / process / report)

export async function claimTasks(client, { workerId, limit = 1, leaseSeconds = 300 }) {
  const { data, error } = await client.rpc("claim_plan_generation_tasks", {
    p_worker_id: workerId,
    p_limit: limit,
    p_lease_seconds: leaseSeconds,
  });
  if (error) throw error;
  return data ?? [];
}

export async function completeTask(client, { taskId, workerId, result }) {
  const { data, error } = await client.rpc("complete_plan_generation_task", {
    p_task_id: taskId,
    p_worker_id: workerId,
    p_result: result ?? null,
  });
  if (error) throw error;
  return data === true;
}

export async function failTask(client, { taskId, workerId, error: message, retryable = true }) {
  const { data, error } = await client.rpc("fail_plan_generation_task", {
    p_task_id: taskId,
    p_worker_id: workerId,
    p_error: message,
    p_retryable: retryable,
  });
  if (error) throw error;
  return data === true;
}

export async function releaseTask(client, { taskId, workerId }) {
  const { data, error } = await client.rpc("release_plan_generation_task", {
    p_task_id: taskId,
    p_worker_id: workerId,
  });
  if (error) throw error;
  return data === true;
}

export async function queueHealth(client, { lagAlertSeconds } = {}) {
  const { data, error } = await client.rpc("plan_generation_queue_health", {
    p_lag_alert_seconds: lagAlertSeconds ?? 900,
  });
  if (error) throw error;
  return data ?? null;
}

// A task needs a meaningful slice of budget to be worth starting: below this
// the LLM call would be aborted almost immediately and the only outcome would
// be a wasted attempt. Better to hand the task back untouched.
export const MIN_TASK_BUDGET_MS = 20_000;

/**
 * Claim a bounded batch and process it, sequentially, inside this request's
 * remaining budget. Returns as soon as the batch is done — it never looks for
 * more work, and never iterates the user base.
 *
 * Sequential is the point, not an oversight (Issue #135 explicitly rules out
 * replacing the serial loop with an unbounded Promise.all): concurrency here
 * would put N unbounded LLM calls inside one 150s request and make the batch
 * as slow as its slowest member. Concurrency belongs at the request level —
 * several worker cron entries — where FOR UPDATE SKIP LOCKED already
 * guarantees isolation.
 *
 * Every handler runs inside its own try/catch and reports its own outcome, so
 * one user's failure, hang or thrown exception cannot touch another's task.
 * That is Issue #135's "单用户超时不阻塞其他用户", expressed structurally
 * rather than by hoping generation stays fast.
 *
 * @param {object} client
 * @param {object} options
 * @param {string} options.workerId - fencing token; must be unique per request
 * @param {number} [options.limit]
 * @param {number} [options.leaseSeconds]
 * @param {number|null} [options.deadlineMs] - epoch ms this request must end by
 * @param {Record<string, (task: object, ctx: object) => Promise<object>>} options.handlers - keyed by task kind
 * @param {object} [options.logger]
 */
export async function processQueueOnce(client, {
  workerId,
  limit = 1,
  leaseSeconds = 300,
  deadlineMs = null,
  handlers,
  logger = console,
}) {
  const tasks = await claimTasks(client, { workerId, limit, leaseSeconds });

  const processed = [];
  let released = 0;

  for (const task of tasks) {
    const remaining = deadlineMs == null ? Number.POSITIVE_INFINITY : deadlineMs - Date.now();
    if (remaining < MIN_TASK_BUDGET_MS) {
      // Hand it straight back: release() refunds the attempt because nothing
      // was actually tried. Without the refund a worker that consistently
      // over-claims would silently burn every task's attempts down to 'failed'
      // without a single LLM call ever being made.
      // deno-lint-ignore no-await-in-loop
      await releaseTask(client, { taskId: task.id, workerId }).catch((error) =>
        logger.error?.(`release of task ${task.id} failed`, error)
      );
      released += 1;
      processed.push({ taskId: task.id, kind: task.kind, userId: task.user_id, outcome: "released" });
      continue;
    }

    const handler = handlers?.[task.kind];
    if (!handler) {
      // An unknown kind can only come from a newer enqueue against an older
      // worker. Non-retryable: no number of retries teaches this build about
      // a kind it does not implement, and leaving it pending would keep it at
      // the head of the FIFO forever, starving everything behind it.
      // deno-lint-ignore no-await-in-loop
      await reportFailure(client, { task, workerId, message: `no handler for task kind "${task.kind}"`, retryable: false, logger });
      processed.push({ taskId: task.id, kind: task.kind, userId: task.user_id, outcome: "failed", error: "unknown kind" });
      continue;
    }

    let outcome;
    try {
      // deno-lint-ignore no-await-in-loop -- see the "sequential is the point"
      // note above; this is the whole design, not a missed optimisation.
      outcome = await handler(task, { deadlineMs, workerId, remainingMs: remaining });
    } catch (error) {
      // A thrown handler is treated as a retryable failure rather than being
      // allowed to abort the loop: the remaining tasks in this batch belong to
      // OTHER users and have nothing to do with this one's bug.
      outcome = { status: "failed", retryable: true, error: String(error?.message ?? error) };
    }

    if (outcome?.status === "succeeded") {
      // deno-lint-ignore no-await-in-loop
      const applied = await completeTask(client, { taskId: task.id, workerId, result: outcome.result ?? null })
        .catch((error) => {
          logger.error?.(`complete of task ${task.id} failed`, error);
          return false;
        });
      // applied=false means the lease was already gone (reclaimed and handed
      // to someone else while this handler ran). The work itself is safe —
      // installs are idempotent — but it must be visible, because it means the
      // lease is too short for real generation times.
      if (!applied) logger.warn?.(`task ${task.id} completed but its lease was no longer held by ${workerId}`);
      processed.push({ taskId: task.id, kind: task.kind, userId: task.user_id, outcome: "succeeded", result: outcome.result ?? null, leaseHeld: applied });
    } else {
      const message = outcome?.error ?? "handler reported failure without an error";
      const retryable = outcome?.retryable !== false;
      // deno-lint-ignore no-await-in-loop
      await reportFailure(client, { task, workerId, message, retryable, logger });
      processed.push({ taskId: task.id, kind: task.kind, userId: task.user_id, outcome: "failed", error: message, retryable });
    }
  }

  return { workerId, claimed: tasks.length, released, processed };
}

async function reportFailure(client, { task, workerId, message, retryable, logger }) {
  try {
    await failTask(client, { taskId: task.id, workerId, error: message, retryable });
  } catch (error) {
    // Nothing better to do: the lease will expire and reclamation will pick
    // the task back up. Logged so "why did this task sit in running" has an
    // answer.
    logger.error?.(`fail report for task ${task.id} failed`, error);
  }
}
