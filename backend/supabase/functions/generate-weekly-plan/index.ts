// generate-weekly-plan: the Phase 2 weekly generation entrypoint, extended
// in Phase 3 with a mid-week replan mode.
// See docs/plans/2026-07-08-phase2-weekly-generation-plan.md §3.4 and
// docs/plans/2026-07-08-phase3-midweek-replan-plan.md §3.2.
//
// Request body: { mode?: 'weekly'|'replan', dry_run?: boolean, user_id?: string, force?: boolean, signal?: string }
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

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DEEPSEEK_API_KEY = Deno.env.get("DEEPSEEK_API_KEY");
const MAX_REPAIR_ATTEMPTS = 2;
const HISTORY_LOOKBACK_DAYS = 28; // ~4 weeks, per plan §3.1
const EVENT_LOOKBACK_DAYS = 14;
const MAX_REPLAN_PER_DAY = 3; // Phase 3 plan §3.2 — shared quota for one-tap + inference
const REPLAN_SIGNALS = new Set(["skip_today", "low_energy", "time_limited"]);

type ReplanSignal = "skip_today" | "low_energy" | "time_limited";
interface RequestBody {
  mode?: "weekly" | "replan";
  dry_run?: boolean;
  user_id?: string;
  force?: boolean;
  signal?: ReplanSignal;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  let body: RequestBody;
  try {
    const text = await req.text();
    body = text ? JSON.parse(text) : {};
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  const mode = body.mode === "replan" ? "replan" : "weekly";
  const secretHeader = req.headers.get("x-generation-secret");

  if (mode === "weekly") {
    // Weekly generation is a backend-only entrypoint — the secret header is
    // the ONLY accepted credential, never a user JWT (Phase 2 plan §4.2
    // "全程零 UI" — the client must never be able to trigger this).
    if (!secretHeader || !(await checkGenerationSecret(admin, secretHeader))) {
      return json({ error: "unauthorized" }, 401);
    }

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

    // Behavioral-inference replan sweep (Phase 3 §3.3): only on the full cron
    // sweep (no explicit user_id, not a dry run) — for every user whose local
    // time is in the evening window AND who has a fully-missed training day
    // today, redistribute the missed volume into their remaining days. Runs in
    // the same hourly tick as weekly generation; the two never conflict
    // (different target weeks). A targeted user_id call is dev tooling for
    // weekly generation only and skips this.
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

// MARK: - User selection (cron-driven path; bypassed when user_id is given)

async function selectDueUsers(admin: ReturnType<typeof createClient>): Promise<string[]> {
  const { data: profiles, error } = await admin.from("profiles").select("id, timezone");
  if (error) throw error;

  const now = new Date();
  const due: string[] = [];
  for (const profile of profiles ?? []) {
    const timezone = profile.timezone || "UTC";
    if (!isGenerationWindowOpen(timezone, now)) continue;

    const weekStartDate = nextMondayString(timezone, now);
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
  return due;
}

/** True from Sunday 20:00 local time through the rest of the week. The
 * "next week's plan already exists" check is what prevents re-generating
 * every hour once it's run once — this window is deliberately wide so a
 * missed hourly tick (deploy hiccup, transient failure) still catches up
 * later in the week instead of waiting a full 7 days. */
function isGenerationWindowOpen(timezone: string, now: Date): boolean {
  const { weekday, hour } = localWeekdayAndHour(timezone, now);
  return weekday !== 0 || hour >= 20; // 0 = Sunday
}

/** Behavioral-inference window: local 21:00–22:59. Late enough that a genuine
 * training day would normally be logged by now, early enough to still leave the
 * user their evening. Deliberately narrow so the hourly cron fires inference at
 * most ~2 times per user per day; the per-day "already replanned" gate collapses
 * that to at most one actual run. */
function isInferenceWindowOpen(timezone: string, now: Date): boolean {
  const { hour } = localWeekdayAndHour(timezone, now);
  return hour >= 21 && hour < 23;
}

/** For every user in their local inference window with a fully-missed training
 * day today, fire one inference replan. The "missed training day + not already
 * replanned today" gate lives here (not in replanForUser) so the one-tap path
 * stays unaffected. */
async function runInferenceSweep(admin: ReturnType<typeof createClient>, now: Date) {
  const { data: profiles, error } = await admin.from("profiles").select("id, timezone");
  if (error) { console.error("inference sweep: profiles fetch failed", error); return []; }

  const results: Array<Record<string, unknown>> = [];
  for (const profile of profiles ?? []) {
    const timezone = profile.timezone || "UTC";
    if (!isInferenceWindowOpen(timezone, now)) continue;

    // deno-lint-ignore no-await-in-loop -- sequential on purpose (see weekly loop).
    const gate = await inferenceGateOpen(admin, profile.id, timezone, now);
    if (!gate) continue;

    // deno-lint-ignore no-await-in-loop
    const result = await replanForUser(admin, profile.id, { dryRun: false, signal: null, trigger: "inference" });
    results.push({ userId: profile.id, ...result });
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

  // Zero of today's sets completed — a partially-done day isn't "missed".
  const { count: completedToday } = await admin
    .from("training_plan_sets").select("id", { count: "exact", head: true })
    .in("plan_exercise_id", exerciseIds)
    .eq("user_id", userId)
    .or("completed_at.not.is.null,linked_exercise_set_id.not.is.null");
  if ((completedToday ?? 0) > 0) return false;

  // Not already replanned today (stricter than the shared 3/day quota).
  const startOfTodayUtc = new Date(`${today}T00:00:00.000Z`).toISOString();
  const { count: replanToday } = await admin
    .from("plan_generations").select("id", { count: "exact", head: true })
    .eq("user_id", userId).eq("kind", "replan").gte("generated_at", startOfTodayUtc);
  if ((replanToday ?? 0) > 0) return false;

  return true;
}

function localWeekdayAndHour(timezone: string, now: Date): { weekday: number; hour: number } {
  const weekdayShort = new Intl.DateTimeFormat("en-US", { timeZone: timezone, weekday: "short" }).format(now);
  const hourStr = new Intl.DateTimeFormat("en-US", { timeZone: timezone, hour: "numeric", hourCycle: "h23" }).format(now);
  const map: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  return { weekday: map[weekdayShort] ?? 0, hour: parseInt(hourStr, 10) };
}

/** The calendar date (yyyy-MM-dd) of the Monday starting the ISO week
 * immediately after `now`'s local week, in `timezone`. Purely calendar-date
 * arithmetic — the RPC independently recomputes this server-side (C21) so
 * any drift here is a missed generation, never an unsafe write. */
function nextMondayString(timezone: string, now: Date): string {
  const { weekday } = localWeekdayAndHour(timezone, now);
  const [year, month, day] = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(now).split("-").map(Number);

  const localMidnightUTC = new Date(Date.UTC(year, month - 1, day));
  const daysSinceMonday = weekday === 0 ? 6 : weekday - 1;
  const thisMonday = new Date(localMidnightUTC);
  thisMonday.setUTCDate(localMidnightUTC.getUTCDate() - daysSinceMonday);
  const nextMonday = new Date(thisMonday);
  nextMonday.setUTCDate(thisMonday.getUTCDate() + 7);
  return nextMonday.toISOString().slice(0, 10);
}

/** The calendar date (yyyy-MM-dd) of the Monday starting `now`'s OWN local
 * week (unlike nextMondayString, no +7 shift) — the current week's plan is
 * keyed by this date. Mirrors the RPC's own `date_trunc('week', ...)`
 * computation (C21/C31's "current week" independently re-derived). */
function thisMondayString(timezone: string, now: Date): string {
  const { weekday } = localWeekdayAndHour(timezone, now);
  const [year, month, day] = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(now).split("-").map(Number);

  const localMidnightUTC = new Date(Date.UTC(year, month - 1, day));
  const daysSinceMonday = weekday === 0 ? 6 : weekday - 1;
  const thisMonday = new Date(localMidnightUTC);
  thisMonday.setUTCDate(localMidnightUTC.getUTCDate() - daysSinceMonday);
  return thisMonday.toISOString().slice(0, 10);
}

/** `now`'s own calendar date (yyyy-MM-dd) in `timezone` — used to decide
 * which of the current week's days are still eligible for replan. */
function localDateString(timezone: string, now: Date): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
}

function weekDatesFor(weekStartDate: string): string[] {
  const start = new Date(`${weekStartDate}T00:00:00Z`);
  return Array.from({ length: 7 }, (_, i) => {
    const d = new Date(start);
    d.setUTCDate(start.getUTCDate() + i);
    return d.toISOString().slice(0, 10);
  });
}

// MARK: - Per-user generation

async function generateForUser(
  admin: ReturnType<typeof createClient>,
  userId: string,
  opts: { dryRun: boolean; force: boolean }
) {
  try {
    const { data: profile, error: profileError } = await admin
      .from("profiles").select("timezone").eq("id", userId).single();
    if (profileError) throw profileError;

    const weekStartDate = nextMondayString(profile?.timezone || "UTC", new Date());

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
        orderIndex: index,
        exerciseName: exercise.exerciseName,
        exerciseId: exercise.exerciseId ?? null,
        exerciseLoadType: exercise.loadType ?? "unknown",
        progressionMode: "ai_generated",
        notes: exercise.notes ?? null,
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
      orderIndex: index,
      exerciseName: exercise.exerciseName,
      exerciseId: exercise.exerciseId ?? null,
      exerciseLoadType: exercise.loadType ?? "unknown",
      progressionMode: "ai_generated",
      notes: exercise.notes ?? null,
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
    const timezone = profile?.timezone || "UTC";
    const now = new Date();
    const today = localDateString(timezone, now);
    const weekMonday = thisMondayString(timezone, now);

    // Shared daily quota across one-tap + inference (plan §3.2/C27) — the
    // check happens before any LLM call or plan lookup, so a caller who's
    // already hit the limit costs nothing beyond this one count query.
    const startOfTodayUtc = new Date(`${today}T00:00:00.000Z`).toISOString();
    const { count, error: countError } = await admin
      .from("plan_generations")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId).eq("kind", "replan").gte("generated_at", startOfTodayUtc);
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

    // C25: one retry on an optimistic-lock conflict — re-read the plan's
    // current revision and try once more before giving up (leaving the
    // plan as whichever version won the race, never a partial write).
    let installResult = await admin.rpc("replan_plan_days", {
      p_user_id: userId, p_plan_id: target.plan.id, p_days: pDays, p_expected_revision: target.plan.revision,
    });
    if (installResult.error?.message?.includes("revision mismatch")) {
      const { data: freshPlan } = await admin.from("training_plans").select("revision")
        .eq("id", target.plan.id).eq("user_id", userId).single();
      if (freshPlan) {
        installResult = await admin.rpc("replan_plan_days", {
          p_user_id: userId, p_plan_id: target.plan.id, p_days: pDays, p_expected_revision: freshPlan.revision,
        });
      }
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
        orderIndex: exIndex,
        exerciseName: exercise.exercise_name,
        exerciseId: exercise.exercise_id ?? null,
        exerciseLoadType: exercise.exercise_load_type ?? "unknown",
        progressionMode: "fallback_repeat",
        notes: null,
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
