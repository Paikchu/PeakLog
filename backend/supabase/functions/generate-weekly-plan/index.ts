// generate-weekly-plan: the Phase 2 weekly generation entrypoint.
// See docs/plans/2026-07-08-phase2-weekly-generation-plan.md §3.4.
//
// Auth: requires a valid x-generation-secret header (checked against Vault
// via check_generation_secret RPC, using this function's own auto-injected
// service-role client — no manually-configured Edge Function secret needed
// for auth itself; DEEPSEEK_API_KEY is the one secret that must be set by
// hand). No end-user JWT path is accepted — this is a backend-only entrypoint,
// entirely invisible to the client (Phase 2 plan §4.2 "全程零 UI").
//
// Request body: { dry_run?: boolean, user_id?: string, force?: boolean }
//   dry_run: run the full pipeline but only write plan_generations
//            (status='draft'); never calls install_generated_plan. This is
//            how prompt quality gets iterated on safely against real data.
//   user_id: target one user instead of scanning all profiles for who's due.
//   force:   skip the "does next week's plan already exist" pre-check.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildContext } from "./_shared/contextBuilder.mjs";
import { validateWeeklyPlan } from "./_shared/validator.mjs";
import { generateWithDeepSeek, generateWithRetry, LlmError } from "./_shared/llm.mjs";
import { SYSTEM_PROMPT, PROMPT_VERSION, buildUserMessage } from "./_shared/prompt.mjs";
import { EXERCISE_LIBRARY, EXERCISE_LIBRARY_VERSION } from "./_shared/exerciseLibrary.mjs";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DEEPSEEK_API_KEY = Deno.env.get("DEEPSEEK_API_KEY");
const MAX_REPAIR_ATTEMPTS = 2;
const HISTORY_LOOKBACK_DAYS = 28; // ~4 weeks, per plan §3.1
const EVENT_LOOKBACK_DAYS = 14;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const secretHeader = req.headers.get("x-generation-secret");
  if (!secretHeader || !(await checkGenerationSecret(admin, secretHeader))) {
    return json({ error: "unauthorized" }, 401);
  }

  let body: { dry_run?: boolean; user_id?: string; force?: boolean };
  try {
    const text = await req.text();
    body = text ? JSON.parse(text) : {};
  } catch {
    return json({ error: "invalid JSON body" }, 400);
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

  return json({ results }, 200);
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
  }
) {
  const { error } = await admin.from("plan_generations").insert({
    user_id: params.userId,
    plan_id: params.planId,
    engine: params.engine,
    model_name: params.engine === "llm" ? "deepseek-chat" : null,
    prompt_version: PROMPT_VERSION,
    context_snapshot: params.context,
    raw_response: params.rawResponse,
    validator_verdicts: params.verdicts,
    status: params.status,
    error: params.error,
  });
  if (error) console.error("failed to write plan_generations", error);
}

// MARK: - Context assembly (I/O glue around the pure contextBuilder.mjs)

async function buildContextForUser(admin: ReturnType<typeof createClient>, userId: string, weekStartDate: string) {
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
      ? admin.from("training_plan_exercises").select("*").in("plan_id", planIds)
      : Promise.resolve({ data: [] as unknown[] }),
    planIds.length
      ? admin.from("training_plan_sets").select("*").in("plan_id", planIds)
      : Promise.resolve({ data: [] as unknown[] }),
    admin.from("plan_edit_events").select("*")
      .eq("user_id", userId).eq("source", "user").gte("occurred_at", eventLookbackDate.toISOString()),
  ]);

  const linkedSetIds = (planSetRows ?? [])
    .map((s: { linked_exercise_set_id: string | null }) => s.linked_exercise_set_id)
    .filter((id: string | null): id is string => id != null);
  const actualSetsById: Record<string, unknown> = {};
  if (linkedSetIds.length) {
    const { data: actualSets } = await admin.from("exercise_sets").select("*").in("id", linkedSetIds);
    for (const row of actualSets ?? []) actualSetsById[(row as { id: string }).id] = row;
  }

  // planExerciseRows must be oldest-week-first for buildExerciseHistory's
  // most-recent-first reduction to come out correct — join back to plans'
  // week_start_date (already fetched ascending) to sort them that way.
  const weekByPlanId = new Map((plans ?? []).map((p) => [p.id, p.week_start_date]));
  const orderedPlanExerciseRows = [...(planExerciseRows ?? [])].sort(
    (a: { plan_id: string }, b: { plan_id: string }) =>
      String(weekByPlanId.get(a.plan_id) ?? "").localeCompare(String(weekByPlanId.get(b.plan_id) ?? ""))
  );

  const context = buildContext({
    goalSpecRow: goalSpecRow ?? null,
    weightUnit: preferencesRow?.weight_unit ?? "kg",
    language: preferencesRow?.language ?? "en",
    planExerciseRows: orderedPlanExerciseRows,
    planSetRows: planSetRows ?? [],
    actualSetsById,
    editEventRows: editEventRows ?? [],
    libraryExercises: EXERCISE_LIBRARY,
    customExercises: customExercises ?? [],
    weekStartDate,
    libraryVersion: EXERCISE_LIBRARY_VERSION,
  });

  // The raw current-week plan structure, for the fallback path only (not
  // part of the LLM-facing context — the LLM sees per-exercise history via
  // exerciseHistory, not the nested plan shape).
  const currentWeekPlanRow = (plans ?? [])
    .filter((p) => p.week_start_date < weekStartDate)
    .sort((a, b) => String(b.week_start_date).localeCompare(String(a.week_start_date)))[0];
  const currentWeekPlan = currentWeekPlanRow
    ? await fetchNestedPlan(admin, currentWeekPlanRow.id)
    : null;

  return { context, currentWeekPlan };
}

async function fetchNestedPlan(admin: ReturnType<typeof createClient>, planId: string) {
  const [{ data: days }, { data: exercises }, { data: sets }] = await Promise.all([
    admin.from("training_plan_days").select("*").eq("plan_id", planId).order("day_index"),
    admin.from("training_plan_exercises").select("*").eq("plan_id", planId).order("order_index"),
    admin.from("training_plan_sets").select("*").eq("plan_id", planId).order("set_index"),
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
