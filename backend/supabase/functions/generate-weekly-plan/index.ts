// generate-weekly-plan: the Phase 2 weekly generation entrypoint, extended
// in Phase 3 with a mid-week replan mode and in Issue #135 with a durable
// task queue.
// See docs/plans/2026-07-08-phase2-weekly-generation-plan.md §3.4 and
// docs/plans/2026-07-08-phase3-midweek-replan-plan.md §3.2.
//
// Request body: { action?: 'enqueue'|'work'|'generate', mode?: 'weekly'|'replan',
//                 dry_run?: boolean, user_id?: string, force?: boolean,
//                 signal?: string, limit?: number, lease_seconds?: number }
//
// ISSUE #135 — WHY THERE IS AN `action` AT ALL
// The cron path used to be "one HTTP request does everything": read every
// profile with a single unpaginated select (silently truncated at PostgREST's
// max_rows = 1000, so user #1001 was invisible rather than late), then
// `await generateForUser` for each due user in sequence, then run the
// behavioral-inference sweep on top. One slow user could burn the whole 150s
// request budget and every user after them in the array was simply never
// executed — with no durable cursor, no per-user retry and no fairness, so
// the same tail starved every week.
//
// The fix splits DECLARING work from DOING work:
//   action='enqueue' (cron, every 15 min) — page through profiles and write
//     one durable task row per due user. No LLM calls, so it always finishes
//     inside the request budget; a scan that runs out of budget anyway
//     resumes from a durable cursor on the next tick.
//   action='work' (cron, every minute, several entries) — claim a SMALL,
//     bounded number of tasks under a lease, process them sequentially,
//     report each outcome, return. The number of users no longer affects any
//     single request's duration, only how many worker ticks drain the queue.
//   action='generate' — the pre-#135 in-request sweep, kept as an explicit
//     ops/dev escape hatch (see below). Never scheduled.
//
// The queue is deliberately NOT a bigger loop and NOT an unbounded
// Promise.all (which the issue rules out): concurrency inside one request
// converts "the tail starves" into "everyone times out together", and still
// binds progress to the lifetime of one HTTP request.
//
// A body with no `action` and no `user_id` (i.e. the literal `{}` the OLD
// cron entry posts) defaults to 'enqueue'. That is what makes the deployment
// order in the PR safe: once this revision is live, the not-yet-migrated
// hourly cron enqueues instead of re-running the broken whole-fleet sweep,
// and the tasks it declares simply wait for the worker cron entries that the
// next migration adds.
//
// mode='weekly' (default) — installs NEXT week's plan. Backend-only: requires
// a valid x-generation-secret header (checked against Vault via
// check_generation_secret RPC, using this function's own auto-injected
// service-role client — no manually-configured Edge Function secret needed
// for auth itself; DEEPSEEK_API_KEY is the one secret that must be set by
// hand). No end-user JWT path is accepted here, ever — entirely invisible to
// the client (Phase 2 plan §4.2 "全程零 UI").
//   dry_run: run the full pipeline but only write plan_generations
//            (status='draft'); never calls install_generated_plan. This is
//            how prompt quality gets iterated on safely against real data.
//   user_id: target one user instead of scanning all profiles for who's due.
//   force:   skip the "does next week's plan already exist" pre-check.
//
// mode='replan' — rewrites a subset of the CURRENT week's days (Phase 3).
// Accepts EITHER the secret header (ops/cron — used for the behavioral-
// inference trigger) OR the target user's own JWT via `Authorization: Bearer`
// (the one-tap trigger from Today). user_id is required; a JWT for a
// different user gets 403. `signal` (skip_today|low_energy|time_limited)
// marks a one-tap call; omitting it marks a behavioral-inference call.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildContext, buildReplanContext, summarizeCurrentWeekDays } from "../_shared/contextBuilder.mjs";
import { validateWeeklyPlan, validateReplanDays } from "../_shared/validator.mjs";
import { generateWithDeepSeek, generateWithRetry, LlmError } from "../_shared/llm.mjs";
import { SYSTEM_PROMPT, PROMPT_VERSION, buildUserMessage, REPLAN_SYSTEM_PROMPT, REPLAN_PROMPT_VERSION, buildReplanUserMessage } from "../_shared/prompt.mjs";
import { EXERCISE_LIBRARY, EXERCISE_LIBRARY_VERSION } from "../_shared/exerciseLibrary.mjs";
import { fetchOwnedActualSets } from "../_shared/ownershipQueries.mjs";
import { localDayUtcRange } from "../_shared/timezone.mjs";
import {
  isGenerationWindowOpen,
  isInferenceWindowOpen,
  nextMondayString,
  thisMondayString,
  localDateString,
  resolveTimezone,
} from "../_shared/generationWindow.mjs";
import {
  enqueueDueTasks,
  isInferenceTaskStale,
  isWeeklyTaskStale,
  processQueueOnce,
  queueHealth,
  scanProfilePages,
} from "../_shared/planGenerationQueue.mjs";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DEEPSEEK_API_KEY = Deno.env.get("DEEPSEEK_API_KEY");
const MAX_REPAIR_ATTEMPTS = 2;

// Supabase Edge Functions kill a request after 150s of idle time. Every
// bounded path in this file measures its own budget against this instead of
// against the platform limit, so we stop and report cleanly (persisting the
// enqueue cursor / releasing an unstarted task) rather than being killed
// mid-write with nothing recorded. 110s leaves ~40s of headroom for the
// final round trips.
const REQUEST_BUDGET_MS = 110_000;
// Claimed per worker request. Small on purpose: tasks inside one request run
// sequentially, so anything past what fits in the budget just gets released
// back untouched. Throughput comes from more worker cron entries, not from a
// bigger batch — see 20260729102000_switch_generation_cron_to_queue.sql.
const DEFAULT_WORKER_LIMIT = 1;
const MAX_WORKER_LIMIT = 5;
// Must outlive the longest possible request or a still-running task would be
// reclaimed underneath its live owner; the SQL clamps this to 30..900s.
const DEFAULT_LEASE_SECONDS = 300;
const HISTORY_LOOKBACK_DAYS = 28; // ~4 weeks, per plan §3.1
const EVENT_LOOKBACK_DAYS = 14;
const MAX_REPLAN_PER_DAY = 3; // Phase 3 plan §3.2 — shared quota for one-tap + inference
const REPLAN_SIGNALS = new Set(["skip_today", "low_energy", "time_limited"]);

type ReplanSignal = "skip_today" | "low_energy" | "time_limited";
type QueueAction = "enqueue" | "work" | "generate";
const QUEUE_ACTIONS = new Set<string>(["enqueue", "work", "generate"]);

interface RequestBody {
  action?: QueueAction;
  mode?: "weekly" | "replan";
  dry_run?: boolean;
  user_id?: string;
  force?: boolean;
  signal?: ReplanSignal;
  limit?: number;
  lease_seconds?: number;
}

/**
 * Which of the three weekly-mode entrypoints this body is asking for.
 *
 * The default matters more than it looks. Anything that names a single user
 * (`user_id`) or asks for a dry run is hand-driven dev/ops tooling and must
 * keep behaving exactly as it did before #135 — those callers want the
 * pipeline to run inline and report its result in the response, not to be
 * told "queued, check back later". Everything else is the cron, and the cron
 * must never again do the whole fleet in one request.
 */
function resolveAction(body: RequestBody): QueueAction {
  if (body.action != null) return body.action;
  if (body.user_id || body.dry_run === true) return "generate";
  return "enqueue";
}

Deno.serve(async (req) => {
  const requestDeadlineMs = Date.now() + REQUEST_BUDGET_MS;
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  let body: RequestBody;
  try {
    const text = await req.text();
    body = text ? JSON.parse(text) : {};
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  if (body.action != null && !QUEUE_ACTIONS.has(body.action)) {
    return json({ error: `invalid action "${body.action}"` }, 400);
  }

  const mode = body.mode === "replan" ? "replan" : "weekly";
  const secretHeader = req.headers.get("x-generation-secret");

  if (mode === "weekly") {
    // Weekly generation is a backend-only entrypoint — the secret header is
    // the ONLY accepted credential, never a user JWT (Phase 2 plan §4.2
    // "全程零 UI" — the client must never be able to trigger this). This
    // covers the queue actions too: `work` leases tasks and spends LLM budget
    // on arbitrary users, so it is at least as sensitive as generation.
    if (!secretHeader || !(await checkGenerationSecret(admin, secretHeader))) {
      return json({ error: "unauthorized" }, 401);
    }

    const action = resolveAction(body);

    if (action === "enqueue") {
      try {
        const summary = await enqueueDueTasks(admin, { deadlineMs: requestDeadlineMs });
        return json({ action: "enqueue", ...summary }, 200);
      } catch (error) {
        console.error("enqueueDueTasks failed", error);
        return json({ error: "failed to enqueue due tasks", detail: String(error) }, 500);
      }
    }

    if (action === "work") {
      try {
        return json(await runWorker(admin, body, requestDeadlineMs), 200);
      } catch (error) {
        console.error("queue worker failed", error);
        return json({ error: "queue worker failed", detail: String(error) }, 500);
      }
    }

    // action === "generate": the pre-#135 in-request path. Reached by a
    // targeted `user_id` call, a `dry_run` prompt-quality run, or an explicit
    // `{"action":"generate"}` from ops. NOT reachable from cron any more —
    // the whole point of the queue is that no scheduled request may ever be
    // O(users) long. Behaviour is deliberately unchanged from before the
    // queue existed, down to which paths skip the inference sweep, because
    // these are the hand-driven tools used to iterate on prompts.
    const dryRun = body.dry_run === true;
    const force = body.force === true;

    let targetUserIds: string[];
    try {
      targetUserIds = body.user_id ? [body.user_id] : await selectDueUsers(admin);
    } catch (error) {
      console.error("selectDueUsers failed", error);
      return json({ error: "failed to select due users", detail: String(error) }, 500);
    }

    const results = [];
    for (const userId of targetUserIds) {
      // deno-lint-ignore no-await-in-loop -- intentionally sequential: each
      // user's failure must not affect another's, and we want independent
      // plan_generations rows written as we go rather than batched.
      const result = await generateForUser(admin, userId, { dryRun, force });
      results.push({ userId, ...result });
    }

    // Behavioral-inference replan sweep (Phase 3 §3.3): only on the full
    // sweep (no explicit user_id, not a dry run) — for every user whose local
    // time is in the evening window AND who has a fully-missed training day
    // today, redistribute the missed volume into their remaining days. The
    // two paths never conflict (different target weeks). A targeted user_id
    // call is dev tooling for weekly generation only and skips this.
    if (!body.user_id && !dryRun) {
      const inferenceResults = await runInferenceSweep(admin, new Date());
      results.push(...inferenceResults);
    }

    return json({ results }, 200);
  }

  // mode === "replan" (Phase 3): the only mode a signed-in user's own JWT
  // may ever invoke, and only ever for their own user_id.
  if (!body.user_id) return json({ error: "user_id required for replan" }, 400);
  if (body.signal != null && !REPLAN_SIGNALS.has(body.signal)) {
    return json({ error: `invalid signal "${body.signal}"` }, 400);
  }

  const auth = await authorizeReplanRequest(req, admin, body.user_id, secretHeader);
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  const dryRun = body.dry_run === true;
  const signal = body.signal ?? null;
  const trigger: "user_tap" | "inference" = signal ? "user_tap" : "inference";

  const result = await replanForUser(admin, body.user_id, { dryRun, signal, trigger });
  return json({ results: [{ userId: body.user_id, ...result }] }, 200);
});

// MARK: - Auth

async function checkGenerationSecret(admin: ReturnType<typeof createClient>, candidate: string): Promise<boolean> {
  const { data, error } = await admin.rpc("check_generation_secret", { candidate });
  if (error) {
    console.error("check_generation_secret RPC failed", error);
    return false;
  }
  return data === true;
}

/**
 * Replan may be triggered either by ops/cron (secret header — used for the
 * behavioral-inference path) or by the user's own JWT (the one-tap path).
 * A JWT belonging to a DIFFERENT user than the target user_id is a 403, not
 * a 401 — the caller is authenticated, just not authorized for this
 * resource. Weekly generation never accepts this path (see the `mode` check
 * in the handler above) — this function is only ever called for replan.
 */
async function authorizeReplanRequest(
  req: Request,
  admin: ReturnType<typeof createClient>,
  targetUserId: string,
  secretHeader: string | null
): Promise<{ ok: true } | { ok: false; status: number; error: string }> {
  if (secretHeader && (await checkGenerationSecret(admin, secretHeader))) {
    return { ok: true };
  }

  const authHeader = req.headers.get("authorization");
  const token = authHeader?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token) return { ok: false, status: 401, error: "unauthorized" };

  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user) return { ok: false, status: 401, error: "unauthorized" };
  if (data.user.id !== targetUserId) {
    return { ok: false, status: 403, error: "forbidden: token does not match user_id" };
  }
  return { ok: true };
}

// MARK: - User selection (action='generate' path only; bypassed when user_id
// is given). The cron equivalent of this now lives in
// _shared/planGenerationQueue.mjs' enqueueDueTasks.

/**
 * Every due user, across the WHOLE profile table.
 *
 * Both this and runInferenceSweep below used to issue a bare
 * `.select("id, timezone")`, which PostgREST silently truncates at max_rows
 * (config.toml = 1000) with no error and no indication that it did — so
 * profile #1001 was not "late to be picked up", it was permanently invisible
 * (Issue #135). They now go through scanProfilePages, the same keyset
 * paginator the enqueue path uses, so there is exactly one implementation of
 * "read every profile" left in the codebase and it is the correct one.
 */
async function selectDueUsers(admin: ReturnType<typeof createClient>): Promise<string[]> {
  const now = new Date();
  const due: string[] = [];

  await scanProfilePages(admin, async (profiles: Array<{ id: string; timezone: string | null }>) => {
    for (const profile of profiles) {
      const timezone = resolveTimezone(profile.timezone);
      if (!isGenerationWindowOpen(timezone, now)) continue;

      const weekStartDate = nextMondayString(timezone, now);
      // deno-lint-ignore no-await-in-loop
      const { data: existing, error: existingError } = await admin
        .from("training_plans")
        .select("id")
        .eq("user_id", profile.id)
        .eq("week_start_date", weekStartDate)
        .maybeSingle();
      if (existingError) {
        console.error(`checking existing plan for ${profile.id} failed`, existingError);
        continue;
      }
      if (!existing) due.push(profile.id);
    }
  });

  return due;
}

/** For every user in their local inference window with a fully-missed training
 * day today, fire one inference replan. The "missed training day + not already
 * replanned today" gate lives here (not in replanForUser) so the one-tap path
 * stays unaffected. Paginated for the same reason as selectDueUsers above. */
async function runInferenceSweep(admin: ReturnType<typeof createClient>, now: Date) {
  const results: Array<Record<string, unknown>> = [];
  try {
    await scanProfilePages(admin, async (profiles: Array<{ id: string; timezone: string | null }>) => {
      for (const profile of profiles) {
        const timezone = resolveTimezone(profile.timezone);
        if (!isInferenceWindowOpen(timezone, now)) continue;

        // deno-lint-ignore no-await-in-loop -- sequential on purpose (see weekly loop).
        const gate = await inferenceGateOpen(admin, profile.id, timezone, now);
        if (!gate) continue;

        // deno-lint-ignore no-await-in-loop
        const result = await replanForUser(admin, profile.id, { dryRun: false, signal: null, trigger: "inference" });
        results.push({ userId: profile.id, ...result });
      }
    });
  } catch (error) {
    console.error("inference sweep: profiles fetch failed", error);
  }
  return results;
}

/** Inference fires only when today was genuinely a missed training day and we
 * haven't already replanned today. */
async function inferenceGateOpen(
  admin: ReturnType<typeof createClient>,
  userId: string,
  timezone: string,
  now: Date
): Promise<boolean> {
  const today = localDateString(timezone, now);
  const weekMonday = thisMondayString(timezone, now);

  const { data: plan } = await admin
    .from("training_plans").select("id")
    .eq("user_id", userId).eq("status", "active").eq("week_start_date", weekMonday)
    .maybeSingle();
  if (!plan) return false;

  const { data: dayRow } = await admin
    .from("training_plan_days").select("id")
    .eq("plan_id", plan.id).eq("user_id", userId).eq("plan_date", today)
    .maybeSingle();
  if (!dayRow) return false; // no plan for today at all

  // Must have planned exercises today (a rest day is not a "missed" day).
  const { data: exercises } = await admin
    .from("training_plan_exercises").select("id")
    .eq("plan_day_id", dayRow.id).eq("user_id", userId);
  const exerciseIds = (exercises ?? []).map((e: { id: string }) => e.id);
  if (exerciseIds.length === 0) return false;

  const { count: completedCardioToday } = await admin
    .from("training_plan_exercises").select("id", { count: "exact", head: true })
    .in("id", exerciseIds)
    .eq("user_id", userId)
    .or("cardio_completed_at.not.is.null,linked_cardio_workout_id.not.is.null");
  if ((completedCardioToday ?? 0) > 0) return false;

  // Zero of today's sets completed — a partially-done day isn't "missed".
  const { count: completedToday } = await admin
    .from("training_plan_sets").select("id", { count: "exact", head: true })
    .in("plan_exercise_id", exerciseIds)
    .eq("user_id", userId)
    .or("completed_at.not.is.null,linked_exercise_set_id.not.is.null");
  if ((completedToday ?? 0) > 0) return false;

  // Not already replanned today (stricter than the shared 3/day quota).
  // Bounded to the user's own local calendar day — both ends derived from
  // their actual timezone offset, not a UTC-midnight approximation (#71).
  const { start: startOfTodayUtc, end: endOfTodayUtc } = localDayUtcRange(today, timezone);
  const { count: replanToday } = await admin
    .from("plan_generations").select("id", { count: "exact", head: true })
    .eq("user_id", userId).eq("kind", "replan")
    .gte("generated_at", startOfTodayUtc.toISOString())
    .lt("generated_at", endOfTodayUtc.toISOString());
  if ((replanToday ?? 0) > 0) return false;

  return true;
}

function weekDatesFor(weekStartDate: string): string[] {
  const start = new Date(`${weekStartDate}T00:00:00Z`);
  return Array.from({ length: 7 }, (_, i) => {
    const d = new Date(start);
    d.setUTCDate(start.getUTCDate() + i);
    return d.toISOString().slice(0, 10);
  });
}

// MARK: - Queue worker (Issue #135)
//
// One request = one bounded batch of claimed tasks, processed sequentially,
// each reporting its own outcome. The generic claim/lease/report machinery
// lives in _shared/planGenerationQueue.mjs (and is unit-tested there); what
// stays here is only the part that actually knows how to generate a plan.

interface QueueTask {
  id: string;
  kind: string;
  user_id: string;
  target_date: string;
  attempt_count: number;
  max_attempts: number;
}

type HandlerOutcome =
  | { status: "succeeded"; result?: Record<string, unknown> }
  | { status: "failed"; retryable: boolean; error: string };

async function runWorker(
  admin: ReturnType<typeof createClient>,
  body: RequestBody,
  deadlineMs: number
) {
  // Clamped here as well as in claim_plan_generation_tasks: the SQL is the
  // authority, but a caller asking for 500 should get a clear small number
  // back in the response rather than silently different behaviour. The
  // ceiling exists because a big batch inside one request is exactly the
  // O(users)-per-request shape this issue is about.
  const requestedLimit = Number(body.limit);
  const limit = Number.isFinite(requestedLimit)
    ? Math.min(Math.max(Math.trunc(requestedLimit), 1), MAX_WORKER_LIMIT)
    : DEFAULT_WORKER_LIMIT;

  const requestedLease = Number(body.lease_seconds);
  const leaseSeconds = Number.isFinite(requestedLease)
    ? Math.trunc(requestedLease)
    : DEFAULT_LEASE_SECONDS;

  // The fencing token. Must be unique per REQUEST, not per deploy: two
  // concurrent worker invocations of the same function revision have to be
  // distinguishable, or complete/fail from one could apply to the other's
  // lease.
  const workerId = `edge-${crypto.randomUUID()}`;

  const summary = await processQueueOnce(admin, {
    workerId,
    limit,
    leaseSeconds,
    deadlineMs,
    // The queue module is a plain .mjs with JSDoc types, so its handler
    // signature widens to `(task: object) => Promise<object>` here; the row
    // shape it hands back is claim_plan_generation_tasks' RETURNS SETOF
    // plan_generation_queue, which QueueTask above mirrors.
    handlers: {
      weekly: (task: object) => handleWeeklyTask(admin, task as QueueTask),
      inference: (task: object) => handleInferenceTask(admin, task as QueueTask),
    },
  });

  // Metrics are read at the end of every worker tick rather than by a
  // separate cron entry: the workers already run every minute, so this gives
  // the backlog/lag alert (acceptance criterion 4) a heartbeat for free, and
  // it lands in the same logs as the work it describes. Best-effort — a
  // metrics failure must never turn a successful batch into a 500.
  let health: unknown = null;
  try {
    health = await queueHealth(admin);
    if ((health as { alert?: boolean } | null)?.alert === true) {
      console.error("plan_generation_queue health alert", health);
    }
  } catch (error) {
    console.error("plan_generation_queue_health failed", error);
  }

  return { action: "work", ...summary, health };
}

/** resolveTimezone'd timezone for a user, or null when the profile is gone
 * (deleted between enqueue and claim). A query error throws, which
 * processQueueOnce turns into a retryable failure — a transient database
 * blip should not burn the task's terminal attempt. */
async function fetchProfileTimezone(
  admin: ReturnType<typeof createClient>,
  userId: string
): Promise<string | null> {
  const { data, error } = await admin
    .from("profiles").select("timezone").eq("id", userId).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  return resolveTimezone(data.timezone);
}

/**
 * ACCEPTANCE CRITERION "重试不重复安装计划" lives here, in three layers:
 *
 *  1. The queue's (kind, user_id, target_date) unique key means there is only
 *     ever ONE task per user per week to begin with, no matter how many times
 *     enqueue runs.
 *  2. This existing-plan check, against the PINNED target_date rather than a
 *     freshly derived "next Monday", so a retry looks at the same week the
 *     first attempt did.
 *  3. install_generated_plan itself (20260708000013) re-checks and raises
 *     `unique_violation` — "a plan for week % already exists for user %" —
 *     inside the same transaction that would do the insert. That is the
 *     authoritative guard; layers 1 and 2 exist so the normal path never has
 *     to rely on an exception, and so a retry that races another worker
 *     resolves as a clean skip instead of a failure.
 */
async function handleWeeklyTask(
  admin: ReturnType<typeof createClient>,
  task: QueueTask
): Promise<HandlerOutcome> {
  const timezone = await fetchProfileTimezone(admin, task.user_id);
  if (timezone == null) {
    return { status: "failed", retryable: false, error: `no profile for user ${task.user_id}` };
  }

  const now = new Date();
  if (isWeeklyTaskStale(task.target_date, timezone, now)) {
    // Non-retryable: install_generated_plan's C21 guard refuses any week that
    // is not strictly in the future, so further attempts provably cannot
    // succeed. Recording it as a terminal failure makes "the queue fell far
    // enough behind that a window closed" visible in the metrics instead of
    // showing up as three identical check_violations.
    return {
      status: "failed",
      retryable: false,
      error: `target week ${task.target_date} is no longer in the future for ${timezone}`,
    };
  }

  const { data: existing, error: existingError } = await admin
    .from("training_plans").select("id")
    .eq("user_id", task.user_id).eq("week_start_date", task.target_date).maybeSingle();
  if (existingError) {
    return { status: "failed", retryable: true, error: `existing-plan check failed: ${existingError.message}` };
  }
  if (existing) {
    return {
      status: "succeeded",
      result: { status: "skipped", reason: "plan already exists for the target week", weekStartDate: task.target_date },
    };
  }

  const result = await generateForUser(admin, task.user_id, {
    dryRun: false,
    force: false,
    weekStartDate: task.target_date,
  }) as Record<string, unknown>;

  if (result.status === "installed" || result.status === "skipped") {
    return { status: "succeeded", result };
  }

  const message = String(result.error ?? `generation returned status ${result.status}`);
  // Lost the race to a concurrent install (or to the user's own client): the
  // plan exists, which is the outcome this task wanted. Not a failure.
  if (/already exists/i.test(message)) {
    return {
      status: "succeeded",
      result: { status: "skipped", reason: "plan already existed at install time", weekStartDate: task.target_date },
    };
  }
  if (/refusing to install a plan for the current or a past week/i.test(message)) {
    return { status: "failed", retryable: false, error: message };
  }
  return { status: "failed", retryable: true, error: message };
}

/**
 * The behavioral-inference half of the old sweep. The expensive "did this
 * user actually miss today" gate runs HERE rather than at enqueue time: it
 * costs five queries per user, which is exactly the kind of per-user work
 * that must not happen inside the fleet-wide scan.
 *
 * A closed gate is a SUCCESS, not a failure — "this user trained today, so
 * there is nothing to redistribute" is the task's correct terminal answer,
 * and retrying it would only re-run the same five queries to the same
 * conclusion.
 */
async function handleInferenceTask(
  admin: ReturnType<typeof createClient>,
  task: QueueTask
): Promise<HandlerOutcome> {
  const timezone = await fetchProfileTimezone(admin, task.user_id);
  if (timezone == null) {
    return { status: "failed", retryable: false, error: `no profile for user ${task.user_id}` };
  }

  const now = new Date();
  if (isInferenceTaskStale(task.target_date, timezone, now)) {
    // Redistributing "today's" missed volume is meaningless once the user's
    // local day has rolled over — the days it would redistribute into are
    // themselves in the past now.
    return {
      status: "failed",
      retryable: false,
      error: `inference task for local day ${task.target_date} is stale (user is now on ${localDateString(timezone, now)})`,
    };
  }

  const gate = await inferenceGateOpen(admin, task.user_id, timezone, now);
  if (!gate) {
    return {
      status: "succeeded",
      result: { status: "no_op", reason: "inference gate closed: today was not a fully-missed training day, or a replan already ran" },
    };
  }

  const result = await replanForUser(admin, task.user_id, {
    dryRun: false, signal: null, trigger: "inference",
  }) as Record<string, unknown>;

  // "rate_limited"/"no_op"/"skipped" are legitimate terminal answers, not
  // errors: the shared 3-per-day replan quota and the eligible-days check are
  // both deliberate refusals, and retrying would just re-derive them.
  if (["replanned", "no_op", "skipped", "rate_limited", "dry_run"].includes(String(result.status))) {
    return { status: "succeeded", result };
  }
  // "conflict" (optimistic-lock revision mismatch) IS worth retrying: the
  // plan moved under us, and the next attempt regenerates against the new
  // revision rather than replaying a stale payload.
  return {
    status: "failed",
    retryable: true,
    error: String(result.error ?? `replan returned status ${result.status}`),
  };
}

// MARK: - Per-user generation

async function generateForUser(
  admin: ReturnType<typeof createClient>,
  userId: string,
  opts: { dryRun: boolean; force: boolean; weekStartDate?: string }
) {
  try {
    const { data: profile, error: profileError } = await admin
      .from("profiles").select("timezone").eq("id", userId).single();
    if (profileError) throw profileError;

    // The queue worker passes the target week PINNED at enqueue time rather
    // than letting this re-derive it (Issue #135): a task declared at local
    // Sunday 23:55 and retried at 00:10 would otherwise silently jump a week
    // forward, generating the week-after-next off a week that has not been
    // trained yet. Every other caller still derives it from `now`, unchanged.
    const weekStartDate = opts.weekStartDate
      ?? nextMondayString(resolveTimezone(profile?.timezone), new Date());

    if (!opts.force) {
      const { data: existing } = await admin
        .from("training_plans").select("id")
        .eq("user_id", userId).eq("week_start_date", weekStartDate).maybeSingle();
      if (existing) return { status: "skipped", reason: "plan already exists for target week", weekStartDate };
    }

    const { context, currentWeekPlan } = await buildContextForUser(admin, userId, weekStartDate);

    let installPlan;
    let engine = "llm";
    let verdicts: unknown[] = [];
    let rawResponse: string | null = null;
    let errorNote: string | null = null;

    if (!DEEPSEEK_API_KEY) {
      engine = "fallback_repeat";
      installPlan = buildFallbackPlan(currentWeekPlan, weekStartDate);
      errorNote = "DEEPSEEK_API_KEY not configured";
    } else {
      const generation = await generateAndValidate(context, weekStartDate);
      rawResponse = generation.rawResponse;
      if (generation.ok) {
        installPlan = buildInstallPlan(generation.clampedPlan, weekStartDate, context);
        verdicts = generation.verdicts;
      } else {
        engine = "fallback_repeat";
        installPlan = buildFallbackPlan(currentWeekPlan, weekStartDate);
        errorNote = generation.error;
      }
    }

    if (opts.dryRun) {
      await recordGeneration(admin, {
        userId, planId: null, engine, context, rawResponse, verdicts,
        status: "draft", error: errorNote,
      });
      return { status: "dry_run", weekStartDate, engine, verdictCount: verdicts.length, error: errorNote };
    }

    const { data: installed, error: installError } = await admin.rpc("install_generated_plan", {
      p_user_id: userId,
      p_plan: installPlan,
    });

    if (installError) {
      await recordGeneration(admin, {
        userId, planId: null, engine, context, rawResponse, verdicts,
        status: "failed", error: installError.message,
      });
      return { status: "failed", weekStartDate, error: installError.message };
    }

    await recordGeneration(admin, {
      userId, planId: installed.planId, engine, context, rawResponse, verdicts,
      status: "active", error: errorNote,
    });

    return {
      status: "installed", weekStartDate, engine,
      planId: installed.planId, archivedCount: installed.archivedCount,
    };
  } catch (error) {
    console.error(`generateForUser(${userId}) failed`, error);
    return { status: "error", error: String((error as Error)?.message ?? error) };
  }
}

async function recordGeneration(
  admin: ReturnType<typeof createClient>,
  params: {
    userId: string; planId: string | null; engine: string;
    context: unknown; rawResponse: string | null; verdicts: unknown[];
    status: string; error: string | null;
    kind?: "weekly" | "replan"; trigger?: "user_tap" | "inference" | null; signal?: ReplanSignal | null;
  }
) {
  const kind = params.kind ?? "weekly";
  const { error } = await admin.from("plan_generations").insert({
    user_id: params.userId,
    plan_id: params.planId,
    engine: params.engine,
    model_name: params.engine === "llm" ? "deepseek-chat" : null,
    prompt_version: kind === "replan" ? REPLAN_PROMPT_VERSION : PROMPT_VERSION,
    context_snapshot: params.context,
    raw_response: params.rawResponse,
    validator_verdicts: params.verdicts,
    status: params.status,
    error: params.error,
    kind,
    trigger: params.trigger ?? null,
    signal: params.signal ?? null,
  });
  if (error) console.error("failed to write plan_generations", error);
}

// MARK: - Context assembly (I/O glue around the pure contextBuilder.mjs)

/**
 * The fact ingredients shared by BOTH weekly generation and replan (goal
 * spec, preferences, progression history, edit events, library) — none of
 * this depends on which week is being planned, only on "now" (the lookback
 * windows) and the user. Kept separate from buildContext's target-week
 * tagging so replan can layer its own current-week overview on top without
 * duplicating any of this fetching.
 */
async function fetchSharedFactInputs(admin: ReturnType<typeof createClient>, userId: string) {
  const lookbackDate = new Date();
  lookbackDate.setUTCDate(lookbackDate.getUTCDate() - HISTORY_LOOKBACK_DAYS);
  const lookbackDateStr = lookbackDate.toISOString().slice(0, 10);

  const eventLookbackDate = new Date();
  eventLookbackDate.setUTCDate(eventLookbackDate.getUTCDate() - EVENT_LOOKBACK_DAYS);

  const [
    { data: goalSpecRow },
    { data: preferencesRow },
    { data: plans },
    { data: customExercises },
  ] = await Promise.all([
    admin.from("user_goal_specs").select("*").eq("user_id", userId).maybeSingle(),
    admin.from("user_preferences").select("weight_unit, language").eq("user_id", userId).maybeSingle(),
    admin.from("training_plans").select("id, week_start_date")
      .eq("user_id", userId).gte("week_start_date", lookbackDateStr).order("week_start_date", { ascending: true }),
    admin.from("custom_exercises").select("*").eq("user_id", userId),
  ]);

  const planIds = (plans ?? []).map((p) => p.id);
  const [{ data: planExerciseRows }, { data: planSetRows }, { data: editEventRows }] = await Promise.all([
    planIds.length
      ? admin.from("training_plan_exercises").select("*").in("plan_id", planIds).eq("user_id", userId)
      : Promise.resolve({ data: [] as unknown[] }),
    planIds.length
      ? admin.from("training_plan_sets").select("*").in("plan_id", planIds).eq("user_id", userId)
      : Promise.resolve({ data: [] as unknown[] }),
    admin.from("plan_edit_events").select("*")
      .eq("user_id", userId).eq("source", "user").gte("occurred_at", eventLookbackDate.toISOString()),
  ]);

  const linkedSetIds = (planSetRows ?? [])
    .map((s: { linked_exercise_set_id: string | null }) => s.linked_exercise_set_id)
    .filter((id: string | null): id is string => id != null);
  const actualSetsById: Record<string, unknown> = {};
  if (linkedSetIds.length) {
    const actualSets = await fetchOwnedActualSets(admin, userId, linkedSetIds);
    for (const row of actualSets) actualSetsById[(row as { id: string }).id] = row;
  }

  // planExerciseRows must be oldest-week-first for buildExerciseHistory's
  // most-recent-first reduction to come out correct — join back to plans'
  // week_start_date (already fetched ascending) to sort them that way.
  const weekByPlanId = new Map((plans ?? []).map((p) => [p.id, p.week_start_date]));
  const orderedPlanExerciseRows = [...(planExerciseRows ?? [])].sort(
    (a: { plan_id: string }, b: { plan_id: string }) =>
      String(weekByPlanId.get(a.plan_id) ?? "").localeCompare(String(weekByPlanId.get(b.plan_id) ?? ""))
  );

  return {
    goalSpecRow: goalSpecRow ?? null,
    weightUnit: preferencesRow?.weight_unit ?? "kg",
    language: preferencesRow?.language ?? "en",
    planExerciseRows: orderedPlanExerciseRows,
    planSetRows: planSetRows ?? [],
    actualSetsById,
    editEventRows: editEventRows ?? [],
    libraryExercises: EXERCISE_LIBRARY,
    customExercises: customExercises ?? [],
    libraryVersion: EXERCISE_LIBRARY_VERSION,
    plans: plans ?? [],
  };
}

async function buildContextForUser(admin: ReturnType<typeof createClient>, userId: string, weekStartDate: string) {
  const shared = await fetchSharedFactInputs(admin, userId);

  const context = buildContext({ ...shared, weekStartDate });

  // The raw current-week plan structure, for the fallback path only (not
  // part of the LLM-facing context — the LLM sees per-exercise history via
  // exerciseHistory, not the nested plan shape).
  const currentWeekPlanRow = shared.plans
    .filter((p) => p.week_start_date < weekStartDate)
    .sort((a, b) => String(b.week_start_date).localeCompare(String(a.week_start_date)))[0];
  const currentWeekPlan = currentWeekPlanRow
    ? await fetchNestedPlan(admin, userId, currentWeekPlanRow.id)
    : null;

  return { context, currentWeekPlan };
}

/**
 * Context + target plan lookup for a replan (Phase 3). Reuses the exact same
 * shared fact ingredients as weekly generation, tagged to the CURRENT week
 * (weekMonday) rather than a future one, plus the current week's full
 * day-by-day state so the LLM can see what it's rewriting.
 */
async function buildReplanContextForUser(
  admin: ReturnType<typeof createClient>,
  userId: string,
  weekMonday: string
) {
  const { data: plan, error: planError } = await admin
    .from("training_plans")
    .select("id, revision")
    .eq("user_id", userId).eq("status", "active").eq("week_start_date", weekMonday)
    .maybeSingle();
  if (planError) throw planError;
  if (!plan) return null;

  const [{ data: dayRows }, { data: exerciseRows }, { data: setRows }] = await Promise.all([
    admin.from("training_plan_days").select("*").eq("plan_id", plan.id).eq("user_id", userId).order("day_index"),
    admin.from("training_plan_exercises").select("*").eq("plan_id", plan.id).eq("user_id", userId),
    admin.from("training_plan_sets").select("*").eq("plan_id", plan.id).eq("user_id", userId),
  ]);

  const shared = await fetchSharedFactInputs(admin, userId);

  return {
    plan: plan as { id: string; revision: number },
    dayRows: dayRows ?? [],
    exerciseRows: exerciseRows ?? [],
    setRows: setRows ?? [],
    shared,
  };
}

async function fetchNestedPlan(admin: ReturnType<typeof createClient>, userId: string, planId: string) {
  const [{ data: days }, { data: exercises }, { data: sets }] = await Promise.all([
    admin.from("training_plan_days").select("*").eq("plan_id", planId).eq("user_id", userId).order("day_index"),
    admin.from("training_plan_exercises").select("*").eq("plan_id", planId).eq("user_id", userId).order("order_index"),
    admin.from("training_plan_sets").select("*").eq("plan_id", planId).eq("user_id", userId).order("set_index"),
  ]);
  const exercisesByDay = new Map<string, unknown[]>();
  for (const ex of exercises ?? []) {
    const dayId = (ex as { plan_day_id: string }).plan_day_id;
    const setsForExercise = (sets ?? []).filter((s) => (s as { plan_exercise_id: string }).plan_exercise_id === (ex as { id: string }).id);
    const entry = { ...ex, sets: setsForExercise };
    if (!exercisesByDay.has(dayId)) exercisesByDay.set(dayId, []);
    exercisesByDay.get(dayId)!.push(entry);
  }
  return {
    days: (days ?? []).map((day) => ({ ...day, exercises: exercisesByDay.get((day as { id: string }).id) ?? [] })),
  };
}

// MARK: - LLM generation + validation + repair loop

async function generateAndValidate(context: Record<string, unknown>, weekStartDate: string) {
  const baseUserMessage = buildUserMessage(context);
  let attempt = 0;
  let lastRawResponse: string | null = null;
  let lastViolations: string[] = [];

  while (attempt <= MAX_REPAIR_ATTEMPTS) {
    const userMessage = attempt === 0
      ? baseUserMessage
      : `${baseUserMessage}\n\nYour previous attempt had these problems — fix them and return the full plan again:\n${lastViolations.map((v) => `- ${v}`).join("\n")}`;

    let generation;
    try {
      generation = await generateWithRetry(generateWithDeepSeek, {
        systemPrompt: SYSTEM_PROMPT,
        userMessage,
        apiKey: DEEPSEEK_API_KEY,
      });
    } catch (error) {
      const message = error instanceof LlmError ? error.message : String(error);
      return { ok: false as const, error: `LLM call failed: ${message}`, rawResponse: lastRawResponse };
    }

    lastRawResponse = generation.rawText;
    const validation = validateWeeklyPlan(generation.parsed, { ...context, weekStartDate });
    if (validation.ok) {
      return { ok: true as const, clampedPlan: validation.clampedPlan, verdicts: validation.verdicts, rawResponse: lastRawResponse };
    }
    lastViolations = validation.structuralViolations;
    attempt += 1;
  }

  return {
    ok: false as const,
    error: `validation failed after ${MAX_REPAIR_ATTEMPTS} repair attempts: ${lastViolations.join("; ")}`,
    rawResponse: lastRawResponse,
  };
}

function buildInstallPlan(clampedPlan: { days: unknown[]; coachSummary?: string }, weekStartDate: string, context: Record<string, unknown>) {
  const goalSpec = context.goalSpec as { isDefault?: boolean } | undefined;
  return {
    weekStartDate,
    goalSnapshot: goalSpec && !goalSpec.isDefault ? JSON.stringify(goalSpec) : null,
    coachSummary: clampedPlan.coachSummary ?? "",
    days: (clampedPlan.days as Array<Record<string, unknown>>).map((day) => ({
      dayIndex: day.dayIndex,
      planDate: day.planDate,
      title: day.title,
      focus: day.focus ?? null,
      status: "planned",
      exercises: ((day.exercises as Array<Record<string, unknown>>) ?? []).map((exercise, index) => ({
        itemType: exercise.itemType,
        orderIndex: index,
        exerciseName: exercise.exerciseName,
        exerciseId: exercise.exerciseId ?? null,
        exerciseLoadType: exercise.loadType ?? "unknown",
        progressionMode: "ai_generated",
        notes: exercise.notes ?? null,
        cardioActivityType: exercise.cardioActivityType ?? null,
        targetDurationMinutes: exercise.targetDurationMinutes ?? null,
        targetDistanceKm: exercise.targetDistanceKm ?? null,
        targetRPE: null,
        sets: ((exercise.sets as Array<Record<string, unknown>>) ?? []).map((set) => ({
          setIndex: set.setIndex,
          targetWeight: set.targetWeight ?? null,
          targetWeightUnit: set.targetWeightUnit ?? context.weightUnit ?? "kg",
          targetReps: set.targetReps,
        })),
      })),
    })),
  };
}

// MARK: - Replan (Phase 3): rewrite a caller-given subset of the current
// week's days. Unlike weekly generation, there is no fallback-to-synthetic
// path (C24) — if the LLM can't produce a valid replan, the original plan
// is left untouched and the attempt is recorded as failed.

async function generateAndValidateReplan(context: Record<string, unknown>, targetDates: string[]) {
  const baseUserMessage = buildReplanUserMessage(context);
  let attempt = 0;
  let lastRawResponse: string | null = null;
  let lastViolations: string[] = [];

  while (attempt <= MAX_REPAIR_ATTEMPTS) {
    const userMessage = attempt === 0
      ? baseUserMessage
      : `${baseUserMessage}\n\nYour previous attempt had these problems — fix them and return the full replan again:\n${lastViolations.map((v) => `- ${v}`).join("\n")}`;

    let generation;
    try {
      generation = await generateWithRetry(generateWithDeepSeek, {
        systemPrompt: REPLAN_SYSTEM_PROMPT,
        userMessage,
        apiKey: DEEPSEEK_API_KEY,
      });
    } catch (error) {
      const message = error instanceof LlmError ? error.message : String(error);
      return { ok: false as const, error: `LLM call failed: ${message}`, rawResponse: lastRawResponse };
    }

    lastRawResponse = generation.rawText;
    const validation = validateReplanDays(generation.parsed, targetDates, context);
    if (validation.ok) {
      return { ok: true as const, clampedPlan: validation.clampedPlan, verdicts: validation.verdicts, rawResponse: lastRawResponse };
    }
    lastViolations = validation.structuralViolations;
    attempt += 1;
  }

  return {
    ok: false as const,
    error: `replan validation failed after ${MAX_REPAIR_ATTEMPTS} repair attempts: ${lastViolations.join("; ")}`,
    rawResponse: lastRawResponse,
  };
}

/** Shape expected by replan_plan_days' p_days param — a subset of
 * buildInstallPlan's day shape (no dayIndex/status: the day row already
 * exists and keeps those, only title/focus/exercises/sets are replaced). */
function buildReplanDaysPayload(clampedPlan: { days: unknown[] }, weightUnit: string) {
  return (clampedPlan.days as Array<Record<string, unknown>>).map((day) => ({
    planDate: day.planDate,
    title: day.title,
    focus: day.focus ?? null,
    exercises: ((day.exercises as Array<Record<string, unknown>>) ?? []).map((exercise, index) => ({
      itemType: exercise.itemType,
      orderIndex: index,
      exerciseName: exercise.exerciseName,
      exerciseId: exercise.exerciseId ?? null,
      exerciseLoadType: exercise.loadType ?? "unknown",
      progressionMode: "ai_generated",
      notes: exercise.notes ?? null,
      cardioActivityType: exercise.cardioActivityType ?? null,
      targetDurationMinutes: exercise.targetDurationMinutes ?? null,
      targetDistanceKm: exercise.targetDistanceKm ?? null,
      targetRPE: null,
      sets: ((exercise.sets as Array<Record<string, unknown>>) ?? []).map((set) => ({
        setIndex: set.setIndex,
        targetWeight: set.targetWeight ?? null,
        targetWeightUnit: set.targetWeightUnit ?? weightUnit ?? "kg",
        targetReps: set.targetReps,
      })),
    })),
  }));
}

async function replanForUser(
  admin: ReturnType<typeof createClient>,
  userId: string,
  opts: { dryRun: boolean; signal: ReplanSignal | null; trigger: "user_tap" | "inference" }
) {
  try {
    const { data: profile, error: profileError } = await admin
      .from("profiles").select("timezone").eq("id", userId).single();
    if (profileError) throw profileError;
    const timezone = resolveTimezone(profile?.timezone);
    const now = new Date();
    const today = localDateString(timezone, now);
    const weekMonday = thisMondayString(timezone, now);

    // Shared daily quota across one-tap + inference (plan §3.2/C27) — the
    // check happens before any LLM call or plan lookup, so a caller who's
    // already hit the limit costs nothing beyond this one count query.
    // Window is the user's own local calendar day, both bounds derived from
    // their actual timezone offset rather than a UTC-midnight approximation
    // that drifts by the offset for every non-UTC user (#71).
    const { start: startOfTodayUtc, end: endOfTodayUtc } = localDayUtcRange(today, timezone);
    const { count, error: countError } = await admin
      .from("plan_generations")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId).eq("kind", "replan")
      .gte("generated_at", startOfTodayUtc.toISOString())
      .lt("generated_at", endOfTodayUtc.toISOString());
    if (countError) throw countError;
    if ((count ?? 0) >= MAX_REPLAN_PER_DAY) {
      return { status: "rate_limited", reason: `daily replan limit (${MAX_REPLAN_PER_DAY}) reached` };
    }

    const target = await buildReplanContextForUser(admin, userId, weekMonday);
    if (!target) return { status: "skipped", reason: "no active plan for the current week" };

    const overview = summarizeCurrentWeekDays({
      dayRows: target.dayRows, exerciseRows: target.exerciseRows, setRows: target.setRows,
    });
    const eligibleFutureDates = overview
      .filter((d: { planDate: string; hasCompletedSets: boolean }) => d.planDate >= today && !d.hasCompletedSets)
      .map((d: { planDate: string }) => d.planDate);

    let targetDates: string[];
    if (opts.trigger === "user_tap") {
      // One-tap signals are about TODAY specifically — with one exception
      // (C22): "low_energy" still makes sense on a day the person already
      // trained today, so it auto-scopes to tomorrow instead of no-op'ing.
      // "skip_today"/"time_limited" only make sense for today itself.
      if (!eligibleFutureDates.includes(today)) {
        if (opts.signal === "low_energy") {
          const tomorrow = eligibleFutureDates.find((d: string) => d > today);
          if (!tomorrow) return { status: "no_op", reason: "no eligible day to apply low_energy to" };
          targetDates = [tomorrow];
        } else {
          return { status: "no_op", reason: "today is not eligible for replan" };
        }
      } else {
        targetDates = [today];
      }
    } else {
      // Behavioral inference deliberately never touches today (plan §3.3) —
      // only redistributes into days strictly after today.
      targetDates = eligibleFutureDates.filter((d: string) => d > today);
      if (targetDates.length === 0) {
        return { status: "no_op", reason: "no eligible remaining days to redistribute into" };
      }
    }

    const context = buildReplanContext({
      ...target.shared,
      weekStartDate: weekMonday,
      currentWeekDayRows: target.dayRows,
      currentWeekExerciseRows: target.exerciseRows,
      currentWeekSetRows: target.setRows,
      targetDates,
      signal: opts.signal,
    });

    if (!DEEPSEEK_API_KEY) {
      const errorNote = "DEEPSEEK_API_KEY not configured";
      await recordGeneration(admin, {
        userId, planId: target.plan.id, engine: "unavailable", context, rawResponse: null, verdicts: [],
        status: "failed", error: errorNote, kind: "replan", trigger: opts.trigger, signal: opts.signal,
      });
      return { status: "failed", error: errorNote };
    }

    const generation = await generateAndValidateReplan(context, targetDates);
    if (!generation.ok) {
      // C24: no fallback-to-synthetic here — the original plan is simply
      // left untouched, which is already a safe, legitimate state.
      await recordGeneration(admin, {
        userId, planId: target.plan.id, engine: "llm", context, rawResponse: generation.rawResponse, verdicts: [],
        status: "failed", error: generation.error, kind: "replan", trigger: opts.trigger, signal: opts.signal,
      });
      return { status: "failed", error: generation.error };
    }

    const pDays = buildReplanDaysPayload(generation.clampedPlan, (context as { weightUnit?: string }).weightUnit ?? "kg");

    if (opts.dryRun) {
      await recordGeneration(admin, {
        userId, planId: target.plan.id, engine: "llm", context, rawResponse: generation.rawResponse, verdicts: generation.verdicts,
        status: "draft", error: null, kind: "replan", trigger: opts.trigger, signal: opts.signal,
      });
      return { status: "dry_run", targetDates, verdictCount: generation.verdicts.length };
    }

    // The generated payload is derived from this exact revision. Replaying it
    // with a newer lock token would overwrite the winner's plan change.
    let installResult = await admin.rpc("replan_plan_days", {
      p_user_id: userId, p_plan_id: target.plan.id, p_days: pDays, p_expected_revision: target.plan.revision,
    });
    if (installResult.error?.message?.includes("revision mismatch")) {
      await recordGeneration(admin, {
        userId, planId: target.plan.id, engine: "llm", context, rawResponse: generation.rawResponse, verdicts: generation.verdicts,
        status: "failed", error: installResult.error.message, kind: "replan", trigger: opts.trigger, signal: opts.signal,
      });
      return { status: "conflict", error: installResult.error.message, baseRevision: target.plan.revision };
    }

    if (installResult.error) {
      await recordGeneration(admin, {
        userId, planId: target.plan.id, engine: "llm", context, rawResponse: generation.rawResponse, verdicts: generation.verdicts,
        status: "failed", error: installResult.error.message, kind: "replan", trigger: opts.trigger, signal: opts.signal,
      });
      return { status: "failed", error: installResult.error.message };
    }

    await recordGeneration(admin, {
      userId, planId: target.plan.id, engine: "llm", context, rawResponse: generation.rawResponse, verdicts: generation.verdicts,
      status: "active", error: null, kind: "replan", trigger: opts.trigger, signal: opts.signal,
    });

    // Record the Agent's structural response as `agent`-sourced edit events —
    // one per replanned day — so the next weekly generation's edit-event
    // context shows the full "user signaled X → Agent did Y" pair, not just the
    // user's signal (plan §3.2). Best-effort: a failure here must not undo an
    // already-committed replan, so it's logged and swallowed.
    await recordAgentReplanEvents(admin, {
      userId,
      planId: target.plan.id,
      trigger: opts.trigger,
      signal: opts.signal,
      days: generation.clampedPlan.days as Array<Record<string, unknown>>,
    });

    return {
      status: "replanned", replannedDates: installResult.data.replannedDates, newRevision: installResult.data.newRevision,
    };
  } catch (error) {
    console.error(`replanForUser(${userId}) failed`, error);
    return { status: "error", error: String((error as Error)?.message ?? error) };
  }
}

async function recordAgentReplanEvents(
  admin: ReturnType<typeof createClient>,
  params: {
    userId: string; planId: string; trigger: "user_tap" | "inference";
    signal: ReplanSignal | null; days: Array<Record<string, unknown>>;
  }
) {
  try {
    const nowIso = new Date().toISOString();
    const baseSeq = Date.now();
    const rows = params.days.map((day, index) => ({
      id: crypto.randomUUID(),
      user_id: params.userId,
      plan_id: params.planId,
      plan_date: day.planDate,
      event_type: "agent_replan_day",
      source: "agent",
      exercise_name: null,
      payload: {
        signal: params.signal,
        trigger: params.trigger,
        title: day.title ?? null,
        exercises: ((day.exercises as Array<Record<string, unknown>>) ?? []).map((e) => e.exerciseName),
      },
      // client_seq is a NOT NULL client-ordering column; for server-authored
      // events there is no client clock, so a monotonic-per-batch value derived
      // from the wall clock keeps ordering sane without colliding.
      client_seq: baseSeq + index,
      occurred_at: nowIso,
    }));
    const { error } = await admin.from("plan_edit_events").insert(rows);
    if (error) console.error("failed to write agent replan events", error);
  } catch (error) {
    console.error("recordAgentReplanEvents threw", error);
  }
}

// MARK: - Fallback (C2): repeat the current week's plan structure, shifted
// to next week's dates. Guarantees the user always has a plan even when the
// LLM is unavailable or never produces a valid result.

function buildFallbackPlan(currentWeekPlan: { days: Array<Record<string, unknown>> } | null, weekStartDate: string) {
  const dates = weekDatesFor(weekStartDate);
  const sourceDays = currentWeekPlan?.days ?? [];
  const days = Array.from({ length: 7 }, (_, index) => {
    const source = sourceDays.find((d) => Number(d.day_index) === index);
    return {
      dayIndex: index,
      planDate: dates[index],
      title: source?.title ?? "Rest",
      focus: source?.focus ?? null,
      status: "planned",
      exercises: ((source?.exercises as Array<Record<string, unknown>>) ?? []).map((exercise, exIndex) => ({
        itemType: exercise.item_type,
        orderIndex: exIndex,
        exerciseName: exercise.exercise_name,
        exerciseId: exercise.exercise_id ?? null,
        exerciseLoadType: exercise.exercise_load_type ?? "unknown",
        progressionMode: "fallback_repeat",
        notes: null,
        cardioActivityType: exercise.cardio_activity_type ?? null,
        targetDurationMinutes: exercise.target_duration_minutes ?? null,
        targetDistanceKm: exercise.target_distance_km ?? null,
        targetRPE: null,
        sets: ((exercise.sets as Array<Record<string, unknown>>) ?? []).map((set) => ({
          setIndex: set.set_index,
          targetWeight: set.target_weight ?? null,
          targetWeightUnit: set.target_weight_unit ?? "kg",
          targetReps: set.target_reps,
        })),
      })),
    };
  });

  return {
    weekStartDate,
    goalSnapshot: null,
    coachSummary: currentWeekPlan
      ? "We couldn't generate a fresh plan this week, so we've repeated your current week. Your progress will pick back up as soon as generation succeeds again."
      : "Welcome! We don't have enough history yet for a tailored plan, so here's a light starter week — add or adjust anything that doesn't fit.",
    days,
  };
}

// MARK: - HTTP helpers

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
