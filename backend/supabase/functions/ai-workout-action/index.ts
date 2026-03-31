import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  createAgentSystemPrompt,
  createWorkoutAgent,
} from "../chat-send-message/agent.ts";
import { getSupabaseAdminClientKey, getSupabaseUserClientKey } from "../chat-send-message/env.ts";
import {
  buildPRSummary,
  buildPRSummaryBlock,
  type PRCandidateExercise,
  type PRSnapshot,
  type PRSummaryItem,
} from "../chat-send-message/pr-summary.ts";
import {
  pickWorkoutSessionDate,
  type AdjustCurrentOrNextWeekPlanToolInput,
  type CommitWorkoutToolInput,
  type CreateOrRefreshWeeklyPlanToolInput,
  type LogPlannedSetCompletionToolInput,
  type RecentSavedRecordSummary,
  type TrainingPlanDayInput,
  type UpdateProfileGoalToolInput,
} from "../chat-send-message/schema.ts";
import {
  aiWorkoutActionRequestSchema,
  buildAIWorkoutActionResponse,
  type AIWorkoutActionContentBlock,
} from "./helpers.ts";

type ParsedStreamPart =
  | { kind: "text-delta"; text: string }
  | { kind: "tool-call"; toolName: string; input: unknown }
  | { kind: "ignored" };

function parseStreamPart(part: unknown): ParsedStreamPart {
  if (typeof part !== "object" || part === null) return { kind: "ignored" };
  const p = part as Record<string, unknown>;
  switch (p.type) {
    case "text-delta":
      return { kind: "text-delta", text: typeof p.text === "string" ? p.text : "" };
    case "tool-call":
      return {
        kind: "tool-call",
        toolName: typeof p.toolName === "string" ? p.toolName : "",
        input: p.input !== undefined ? p.input : p.args,
      };
    default:
      return { kind: "ignored" };
  }
}

interface RequestBody {
  text: string;
  targetDate?: string;
}

interface ContentBlockText {
  type: "text";
  text: string;
}

interface ContentBlockSetItem {
  set_id: string;
  set_index: number;
  weight: number | null;
  weight_unit: string;
  reps: number | null;
}

interface ContentBlockExercise {
  exercise_id: string;
  name: string;
  order_index: number;
  sets: ContentBlockSetItem[];
}

interface ContentBlockWorkoutRecord {
  type: "workout_record";
  workout_session_id: string;
  workout_date: string;
  title: string | null;
  parse_status: string;
  exercises: ContentBlockExercise[];
}

interface ContentBlockPRSummary {
  type: "pr_summary";
  summary_text: string;
  items: PRSummaryItem[];
}

interface ContentBlockPlanSet {
  plan_set_id: string;
  set_index: number;
  target_weight: number | null;
  target_weight_unit: string;
  target_reps: number;
  completed_at?: string | null;
  linked_exercise_set_id?: string | null;
}

interface ContentBlockPlanExercise {
  plan_exercise_id: string;
  order_index: number;
  exercise_name: string;
  progression_mode: "weight_first" | "reps_first" | "maintain";
  notes?: string | null;
  sets: ContentBlockPlanSet[];
}

interface ContentBlockPlanDay {
  plan_day_id: string;
  plan_date: string;
  day_index: number;
  title: string;
  focus?: string | null;
  status: "planned" | "in_progress" | "completed" | "skipped" | "rest";
  exercises: ContentBlockPlanExercise[];
}

interface ContentBlockWeeklyPlan {
  type: "weekly_plan";
  plan_id: string;
  week_start_date: string;
  goal_summary: string | null;
  coach_summary: string;
  days: ContentBlockPlanDay[];
}

interface ContentBlockTodayPlan {
  type: "today_plan";
  plan_id: string;
  goal_summary: string | null;
  day: ContentBlockPlanDay;
}

interface ContentBlockPlanAdjustmentSummary {
  type: "plan_adjustment_summary";
  summary_text: string;
}

interface ContentBlockQuickAction {
  type: "quick_action";
  id: string;
  title: string;
  prompt: string;
}

interface ContentBlockExerciseInsight {
  type: "exercise_insight";
  exercise_name: string;
  previous_performance_summary?: string;
  suggestion?: string;
}

type ContentBlock =
  | ContentBlockText
  | ContentBlockWorkoutRecord
  | ContentBlockPRSummary
  | ContentBlockWeeklyPlan
  | ContentBlockTodayPlan
  | ContentBlockPlanAdjustmentSummary
  | ContentBlockQuickAction
  | ContentBlockExerciseInsight;

interface BuildWorkoutResult {
  contentBlocks: ContentBlock[];
}

interface AssistantToolResult {
  contentBlocks: ContentBlock[];
}

interface StoredTrainingPlanSet {
  id: string;
  set_index: number;
  target_weight: number | null;
  target_weight_unit: string;
  target_reps: number;
  completed_at?: string | null;
  linked_exercise_set_id?: string | null;
}

interface StoredTrainingPlanExercise {
  id: string;
  order_index: number;
  exercise_name: string;
  progression_mode: "weight_first" | "reps_first" | "maintain";
  notes?: string | null;
  training_plan_sets?: StoredTrainingPlanSet[];
}

interface StoredTrainingPlanDay {
  id: string;
  plan_date: string;
  day_index: number;
  title: string;
  focus?: string | null;
  status: "planned" | "in_progress" | "completed" | "skipped" | "rest";
  training_plan_exercises?: StoredTrainingPlanExercise[];
}

interface StoredTrainingPlan {
  id: string;
  week_start_date: string;
  goal_snapshot?: string | null;
  coach_summary: string;
  status: string;
  training_plan_days?: StoredTrainingPlanDay[];
}

interface SessionExerciseSetRow {
  weight: number | null;
  weight_unit: string;
  reps: number | null;
}

interface SessionExerciseRow {
  name: string;
  exercise_sets?: SessionExerciseSetRow[];
}

interface RecentSessionRow {
  id: string;
  workout_date: string;
  exercises?: SessionExerciseRow[];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const userClientKey = getSupabaseUserClientKey(Deno.env.toObject());
  const adminClientKey = getSupabaseAdminClientKey(Deno.env.toObject());
  const deepseekApiKey = Deno.env.get("DEEPSEEK_API_KEY");

  if (!supabaseUrl || !userClientKey || !adminClientKey || !deepseekApiKey) {
    return jsonResponse({ error: "Missing required environment variables" }, 500);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonResponse({ error: "Missing authorization header" }, 401);
  }

  const supabaseUser = createClient(supabaseUrl, userClientKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const supabaseAdmin = createClient(supabaseUrl, adminClientKey);

  const {
    data: { user },
    error: authError,
  } = await supabaseUser.auth.getUser();

  if (authError || !user) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const parsedBody = aiWorkoutActionRequestSchema.safeParse(body);
  if (!parsedBody.success) {
    return jsonResponse({ error: parsedBody.error.message }, 400);
  }

  const text = parsedBody.data.text.trim();
  const today = parsedBody.data.targetDate ?? new Date().toISOString().split("T")[0];
  const sourceMessageId: string | null = null;

  try {
    const {
      recentSavedRecords,
      profileGoalSummary,
      activeWeeklyPlanSummary,
      todayPlanSummary,
      recentPlanAdherenceSummary,
    } = await loadActionContext(supabaseAdmin, user.id, today);

    let assistantToolResult: AssistantToolResult | null = null;

    const agent = createWorkoutAgent({
      apiKey: deepseekApiKey,
      system: createAgentSystemPrompt(
        today,
        recentSavedRecords,
        profileGoalSummary,
        activeWeeklyPlanSummary,
        todayPlanSummary,
        recentPlanAdherenceSummary,
      ),
      onCommitWorkout: async (parsed) => {
        const commitResult = await persistCommitWorkoutInTool({
          supabaseAdmin,
          userId: user.id,
          sourceMessageId,
          parsed,
          today,
        });
        assistantToolResult = { contentBlocks: commitResult.contentBlocks };
      },
      onUpdateProfileGoal: async (parsed) => {
        assistantToolResult = await persistProfileGoalUpdateInTool({
          supabaseAdmin,
          userId: user.id,
          parsed,
        });
      },
      onCreateOrRefreshWeeklyPlan: async (parsed) => {
        assistantToolResult = await persistWeeklyPlanInTool({
          supabaseAdmin,
          userId: user.id,
          sourceMessageId,
          parsed,
          today,
        });
      },
      onAdjustCurrentOrNextWeekPlan: async (parsed) => {
        assistantToolResult = await persistWeeklyPlanAdjustmentInTool({
          supabaseAdmin,
          userId: user.id,
          sourceMessageId,
          parsed,
          today,
        });
      },
      onLogPlannedSetCompletion: async (parsed) => {
        assistantToolResult = await persistPlannedSetCompletionInTool({
          supabaseAdmin,
          userId: user.id,
          parsed,
          today,
        });
      },
    });

    const streamResult = await agent.stream({
      messages: [{ role: "user" as const, content: text }],
    });

    let accumulatedText = "";
    let sawAnyToolCall = false;
    const toolNamesSeen = new Set<string>();
    const toolInputsSeen: Array<{ toolName: string; input: unknown }> = [];

    for await (const part of streamResult.fullStream) {
      const parsed = parseStreamPart(part);
      switch (parsed.kind) {
        case "text-delta":
          accumulatedText += parsed.text;
          break;
        case "tool-call":
          sawAnyToolCall = true;
          if (parsed.toolName) {
            toolNamesSeen.add(parsed.toolName);
            toolInputsSeen.push({ toolName: parsed.toolName, input: parsed.input });
          }
          break;
        case "ignored":
          break;
      }
    }

    if (assistantToolResult === null && sawAnyToolCall) {
      return jsonResponse({
        error: "Tool call did not produce a persisted result",
        toolNames: [...toolNamesSeen],
        toolInputs: toolInputsSeen,
      }, 500);
    }

    const response = buildAIWorkoutActionResponse(
      assistantToolResult as { contentBlocks: AIWorkoutActionContentBlock[] } | null,
      accumulatedText.trim(),
    );

    if (assistantToolResult === null && response.reply.length === 0) {
      response.status = "clarify";
      response.reply = "我需要更多信息才能完成这次调整，请再具体一点。";
    } else if (assistantToolResult === null) {
      response.status = "clarify";
    }

    return jsonResponse(response);
  } catch (error) {
    console.error("ai-workout-action failed", error);
    return jsonResponse({
      error: error instanceof Error ? error.message : "Unknown server error",
    }, 500);
  }
});

function corsHeaders(): HeadersInit {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(),
      "Content-Type": "application/json",
    },
  });
}

async function loadActionContext(
  supabaseAdmin: any,
  userId: string,
  today: string,
): Promise<{
  recentSavedRecords: RecentSavedRecordSummary[];
  profileGoalSummary: string | null;
  activeWeeklyPlanSummary: string;
  todayPlanSummary: string;
  recentPlanAdherenceSummary: string;
}> {
  const recentSavedRecords = await fetchRecentSavedRecordSummariesFromSessions(supabaseAdmin, userId);
  const profileGoalSummary = await fetchProfileGoalSummary(supabaseAdmin, userId);
  const activePlan = await fetchActiveWeeklyPlan(supabaseAdmin, userId);

  return {
    recentSavedRecords,
    profileGoalSummary,
    activeWeeklyPlanSummary: summarizeWeeklyPlan(activePlan),
    todayPlanSummary: summarizeTodayPlan(activePlan, today),
    recentPlanAdherenceSummary: await summarizeRecentPlanAdherence(supabaseAdmin, userId),
  };
}

async function persistCommitWorkoutInTool({
  supabaseAdmin,
  userId,
  sourceMessageId,
  parsed,
  today,
}: {
  supabaseAdmin: any;
  userId: string;
  sourceMessageId: string | null;
  parsed: CommitWorkoutToolInput;
  today: string;
}): Promise<BuildWorkoutResult> {
  return await buildWorkoutAndContentBlocks(
    supabaseAdmin,
    userId,
    sourceMessageId,
    parsed,
    today,
  );
}

async function persistProfileGoalUpdateInTool({
  supabaseAdmin,
  userId,
  parsed,
}: {
  supabaseAdmin: any;
  userId: string;
  parsed: UpdateProfileGoalToolInput;
}): Promise<AssistantToolResult> {
  const { error } = await supabaseAdmin
    .from("profiles")
    .update({ fitness_goal_summary: parsed.goalSummary })
    .eq("id", userId);

  if (error) {
    throw new Error(`Failed to update profile goal: ${error.message}`);
  }

  return {
    contentBlocks: [
      { type: "text", text: parsed.reply },
      { type: "plan_adjustment_summary", summary_text: `已更新目标：${parsed.goalSummary}` },
    ],
  };
}

async function persistWeeklyPlanInTool({
  supabaseAdmin,
  userId,
  sourceMessageId,
  parsed,
  today,
}: {
  supabaseAdmin: any;
  userId: string;
  sourceMessageId: string | null;
  parsed: CreateOrRefreshWeeklyPlanToolInput;
  today: string;
}): Promise<AssistantToolResult> {
  const goalSummary = await fetchProfileGoalSummary(supabaseAdmin, userId);
  const plan = await upsertStructuredWeeklyPlan({
    supabase: supabaseAdmin,
    userId,
    sourceMessageId,
    weekStartDate: parsed.weekStartDate,
    coachSummary: parsed.coachSummary,
    days: parsed.days,
    goalSummary,
  });

  return buildWeeklyPlanAssistantResult({
    reply: parsed.reply,
    goalSummary,
    coachSummary: parsed.coachSummary,
    plan,
    today,
  });
}

async function persistWeeklyPlanAdjustmentInTool({
  supabaseAdmin,
  userId,
  sourceMessageId,
  parsed,
  today,
}: {
  supabaseAdmin: any;
  userId: string;
  sourceMessageId: string | null;
  parsed: AdjustCurrentOrNextWeekPlanToolInput;
  today: string;
}): Promise<AssistantToolResult> {
  const goalSummary = await fetchProfileGoalSummary(supabaseAdmin, userId);
  const plan = await upsertStructuredWeeklyPlan({
    supabase: supabaseAdmin,
    userId,
    sourceMessageId,
    weekStartDate: parsed.targetWeek,
    coachSummary: parsed.coachSummary,
    days: parsed.days,
    goalSummary,
  });

  const result = buildWeeklyPlanAssistantResult({
    reply: parsed.reply,
    goalSummary,
    coachSummary: parsed.coachSummary,
    plan,
    today,
  });
  result.contentBlocks.push({
    type: "plan_adjustment_summary",
    summary_text: parsed.adjustmentReason,
  });
  return result;
}

async function persistPlannedSetCompletionInTool({
  supabaseAdmin,
  userId,
  parsed,
  today,
}: {
  supabaseAdmin: any;
  userId: string;
  parsed: LogPlannedSetCompletionToolInput;
  today: string;
}): Promise<AssistantToolResult> {
  const completion = await completePlannedSet({
    supabase: supabaseAdmin,
    userId,
    planSetId: parsed.planSetId,
    actualWeight: parsed.actualWeight,
    actualWeightUnit: parsed.actualWeightUnit,
    actualReps: parsed.actualReps,
    today,
  });

  const goalSummary = await fetchProfileGoalSummary(supabaseAdmin, userId);
  const activePlan = await fetchActiveWeeklyPlan(supabaseAdmin, userId);
  const blocks: ContentBlock[] = [{ type: "text", text: parsed.reply }];
  if (activePlan) {
    blocks.push(weeklyPlanContentBlockFromPlan(activePlan, goalSummary));
    const todayBlock = todayPlanContentBlockFromPlan(activePlan, today, goalSummary);
    if (todayBlock) {
      blocks.push(todayBlock);
      blocks.push(...buildTodayPlanGuidanceBlocks(todayBlock));
    }
  }
  blocks.push({
    type: "plan_adjustment_summary",
    summary_text: `已记录 ${completion.exerciseName} 第 ${completion.setIndex} 组：${completion.summaryText}`,
  });
  return { contentBlocks: blocks };
}

async function buildWorkoutAndContentBlocks(
  supabase: any,
  userId: string,
  sourceMessageId: string | null,
  parsed: CommitWorkoutToolInput,
  fallbackDate: string,
): Promise<BuildWorkoutResult> {
  const blocks: ContentBlock[] = [{ type: "text", text: parsed.reply }];
  const exercises = parsed.exercises ?? [];
  if (exercises.length === 0) return { contentBlocks: blocks };

  const workoutDate = pickWorkoutSessionDate(parsed.workoutDate, fallbackDate);
  const previousPRs = await safeFetchExercisePRMap(supabase, userId);

  let sessionId: string;
  const { data: existingSession } = await supabase
    .from("workout_sessions")
    .select("id")
    .eq("user_id", userId)
    .eq("workout_date", workoutDate)
    .is("deleted_at", null)
    .limit(1)
    .maybeSingle();

  if (existingSession) {
    sessionId = existingSession.id;
  } else {
    const { data: newSession, error: sessionError } = await supabase
      .from("workout_sessions")
      .insert({
        user_id: userId,
        source_message_id: sourceMessageId ?? null,
        workout_date: workoutDate,
        source_type: "ai_action",
        parse_status: "completed",
        confirmation_status: "confirmed",
      })
      .select()
      .single();

    if (sessionError || !newSession) {
      throw new Error(`Failed to create workout_session: ${sessionError?.message}`);
    }
    sessionId = newSession.id;
  }

  const { data: existingExercises } = await supabase
    .from("exercises")
    .select("order_index")
    .eq("session_id", sessionId)
    .is("deleted_at", null)
    .order("order_index", { ascending: false })
    .limit(1);

  let orderOffset = existingExercises?.[0]?.order_index != null ? existingExercises[0].order_index + 1 : 0;

  const exerciseBlocks: ContentBlockExercise[] = [];
  const candidateExercises: PRCandidateExercise[] = [];

  interface InsertedExerciseRow {
    id: string;
    name: string;
    normalized_name: string;
    order_index: number;
  }

  interface InsertedSetRow {
    id: string;
    set_index: number;
    weight: number | null;
    weight_unit: string;
    reps: number | null;
  }

  for (const parsedExercise of exercises) {
    const { data: exerciseRow, error: exerciseError } = await supabase
      .from("exercises")
      .insert({
        session_id: sessionId,
        user_id: userId,
        name: parsedExercise.name,
        normalized_name: parsedExercise.name.toLowerCase().trim(),
        order_index: orderOffset++,
      })
      .select()
      .single();

    const insertedExercise = exerciseRow as InsertedExerciseRow | null;
    if (exerciseError || !insertedExercise) {
      throw new Error(`Failed to insert exercise: ${exerciseError?.message}`);
    }

    const setRows = parsedExercise.sets.map((set) => ({
      exercise_id: insertedExercise.id,
      user_id: userId,
      set_index: set.setIndex,
      weight: set.weight ?? null,
      weight_unit: set.weightUnit ?? "kg",
      reps: set.reps ?? null,
    }));

    const { data: insertedSets, error: setsError } = await supabase
      .from("exercise_sets")
      .insert(setRows)
      .select();

    const createdSets = (insertedSets ?? []) as InsertedSetRow[];
    if (setsError || !insertedSets) {
      throw new Error(`Failed to insert exercise_sets: ${setsError?.message}`);
    }

    const maxSet = createdSets.reduce<InsertedSetRow | null>((best, current) => {
      if (!best) return current;
      return Number(current.weight ?? Number.NEGATIVE_INFINITY) > Number(best.weight ?? Number.NEGATIVE_INFINITY)
        ? current
        : best;
    }, createdSets[0] ?? null);

    if (maxSet?.weight != null) {
      candidateExercises.push({
        normalizedName: insertedExercise.normalized_name,
        displayName: insertedExercise.name,
        maxWeight: Number(maxSet.weight),
        weightUnit: maxSet.weight_unit,
      });
    }

    exerciseBlocks.push({
      exercise_id: insertedExercise.id,
      name: insertedExercise.name,
      order_index: insertedExercise.order_index,
      sets: createdSets.map((set) => ({
        set_id: set.id,
        set_index: set.set_index,
        weight: set.weight,
        weight_unit: set.weight_unit,
        reps: set.reps,
      })),
    });
  }

  blocks.push({
    type: "workout_record",
    workout_session_id: sessionId,
    workout_date: workoutDate,
    title: null,
    parse_status: "completed",
    exercises: exerciseBlocks,
  });

  const prRefreshAvailable = await safeRefreshExercisePRs(supabase, userId);
  if (prRefreshAvailable) {
    const currentPRs = await safeFetchExercisePRMap(supabase, userId);
    const prSummary = buildPRSummary({
      previousPRs,
      currentPRs,
      candidateExercises,
    });
    const prSummaryBlock = buildPRSummaryBlock(prSummary);
    if (prSummaryBlock) {
      blocks.push(prSummaryBlock);
    }
  }

  return { contentBlocks: blocks };
}

async function fetchProfileGoalSummary(
  supabase: any,
  userId: string,
): Promise<string | null> {
  const { data } = await supabase
    .from("profiles")
    .select("fitness_goal_summary")
    .eq("id", userId)
    .maybeSingle();

  return data?.fitness_goal_summary ?? null;
}

async function fetchActiveWeeklyPlan(
  supabase: any,
  userId: string,
): Promise<StoredTrainingPlan | null> {
  const { data, error } = await supabase
    .from("training_plans")
    .select(
      "id, week_start_date, goal_snapshot, coach_summary, status, training_plan_days(id, plan_date, day_index, title, focus, status, training_plan_exercises(id, order_index, exercise_name, progression_mode, notes, training_plan_sets(id, set_index, target_weight, target_weight_unit, target_reps, completed_at, linked_exercise_set_id)))",
    )
    .eq("user_id", userId)
    .eq("status", "active")
    .order("week_start_date", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) {
    console.warn("Failed to fetch active weekly plan", error);
    return null;
  }

  return data as StoredTrainingPlan | null;
}

function summarizeWeeklyPlan(plan: StoredTrainingPlan | null): string {
  if (!plan) return "None.";
  const days = [...(plan.training_plan_days ?? [])].sort((a, b) => a.day_index - b.day_index);
  if (days.length === 0) {
    return `Week ${plan.week_start_date}: no structured days yet.`;
  }

  return days.map((day) => {
    const exerciseCount = day.training_plan_exercises?.length ?? 0;
    return `${day.plan_date} ${day.title} (${day.status})${exerciseCount > 0 ? ` - ${exerciseCount} exercises` : ""}`;
  }).join("\n");
}

function summarizeTodayPlan(plan: StoredTrainingPlan | null, today: string): string {
  if (!plan) return "None.";
  const day = (plan.training_plan_days ?? []).find((item) => item.plan_date === today);
  if (!day) return "No plan day for today.";
  const exercises = day.training_plan_exercises ?? [];
  if (exercises.length === 0) {
    return `${day.title} (${day.status})`;
  }
  return `${day.title} (${day.status})\n` + exercises.map((exercise) =>
    `${exercise.exercise_name}: ${(exercise.training_plan_sets ?? []).length} sets`
  ).join("\n");
}

async function summarizeRecentPlanAdherence(
  supabase: any,
  userId: string,
): Promise<string> {
  const { data } = await supabase
    .from("training_plans")
    .select("id, week_start_date, training_plan_days(id, training_plan_exercises(id, training_plan_sets(id, completed_at)))")
    .eq("user_id", userId)
    .eq("status", "active")
    .order("week_start_date", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!data) return "No tracked adherence yet.";

  const days = data.training_plan_days ?? [];
  let totalSets = 0;
  let completedSets = 0;
  for (const day of days) {
    for (const exercise of day.training_plan_exercises ?? []) {
      for (const set of exercise.training_plan_sets ?? []) {
        totalSets += 1;
        if (set.completed_at) {
          completedSets += 1;
        }
      }
    }
  }

  if (totalSets === 0) return "No tracked adherence yet.";
  return `Completed ${completedSets}/${totalSets} planned sets in the latest tracked week.`;
}

async function upsertStructuredWeeklyPlan({
  supabase,
  userId,
  sourceMessageId,
  weekStartDate,
  coachSummary,
  days,
  goalSummary,
}: {
  supabase: any;
  userId: string;
  sourceMessageId: string | null;
  weekStartDate: string;
  coachSummary: string;
  days: TrainingPlanDayInput[];
  goalSummary: string | null;
}): Promise<StoredTrainingPlan> {
  await supabase.from("training_plans").update({ status: "archived" }).eq("user_id", userId).eq("status", "active");

  const { data: existing } = await supabase
    .from("training_plans")
    .select("id")
    .eq("user_id", userId)
    .eq("week_start_date", weekStartDate)
    .limit(1)
    .maybeSingle();

  let planId = existing?.id as string | undefined;
  if (planId) {
    await supabase.from("training_plan_sets").delete().eq("user_id", userId).eq("plan_id", planId);
    await supabase.from("training_plan_exercises").delete().eq("user_id", userId).eq("plan_id", planId);
    await supabase.from("training_plan_days").delete().eq("user_id", userId).eq("plan_id", planId);
    await supabase
      .from("training_plans")
      .update({
        status: "active",
        goal_snapshot: goalSummary,
        coach_summary: coachSummary,
        source_message_id: sourceMessageId ?? null,
      })
      .eq("id", planId);
  } else {
    const { data: createdPlan, error: planError } = await supabase
      .from("training_plans")
      .insert({
        user_id: userId,
        week_start_date: weekStartDate,
        status: "active",
        goal_snapshot: goalSummary,
        coach_summary: coachSummary,
        source_message_id: sourceMessageId ?? null,
      })
      .select("id")
      .single();
    if (planError || !createdPlan) {
      throw new Error(`Failed to create weekly plan: ${planError?.message}`);
    }
    planId = createdPlan.id;
  }

  for (const day of days) {
    const { data: createdDay, error: dayError } = await supabase
      .from("training_plan_days")
      .insert({
        plan_id: planId,
        user_id: userId,
        plan_date: day.planDate,
        day_index: day.dayIndex,
        title: day.title,
        focus: day.focus ?? null,
        status: day.status,
      })
      .select("id")
      .single();
    if (dayError || !createdDay) {
      throw new Error(`Failed to create plan day: ${dayError?.message}`);
    }

    for (const exercise of day.exercises) {
      const { data: createdExercise, error: exerciseError } = await supabase
        .from("training_plan_exercises")
        .insert({
          plan_id: planId,
          plan_day_id: createdDay.id,
          user_id: userId,
          order_index: exercise.orderIndex,
          exercise_name: exercise.exerciseName,
          progression_mode: exercise.progressionMode,
          notes: exercise.notes ?? null,
        })
        .select("id")
        .single();
      if (exerciseError || !createdExercise) {
        throw new Error(`Failed to create plan exercise: ${exerciseError?.message}`);
      }

      const setRows = exercise.sets.map((set) => ({
        plan_id: planId,
        plan_exercise_id: createdExercise.id,
        user_id: userId,
        set_index: set.setIndex,
        target_weight: set.targetWeight,
        target_weight_unit: set.targetWeightUnit,
        target_reps: set.targetReps,
      }));
      const { error: setError } = await supabase.from("training_plan_sets").insert(setRows);
      if (setError) {
        throw new Error(`Failed to create plan sets: ${setError.message}`);
      }
    }
  }

  const finalPlan = await fetchActiveWeeklyPlan(supabase, userId);
  if (!finalPlan) {
    throw new Error("Failed to reload active weekly plan after upsert");
  }
  return finalPlan;
}

async function completePlannedSet({
  supabase,
  userId,
  planSetId,
  actualWeight,
  actualWeightUnit,
  actualReps,
  today,
}: {
  supabase: any;
  userId: string;
  planSetId: string;
  actualWeight: number | null;
  actualWeightUnit: string;
  actualReps: number;
  today: string;
}): Promise<{ exerciseName: string; setIndex: number; summaryText: string }> {
  const { data: planSetRow, error } = await supabase
    .from("training_plan_sets")
    .select(
      "id, set_index, target_weight, target_weight_unit, target_reps, linked_exercise_set_id, plan_exercise_id, training_plan_exercises!inner(id, exercise_name)",
    )
    .eq("id", planSetId)
    .eq("user_id", userId)
    .single();

  if (error || !planSetRow) {
    throw new Error(`Failed to load plan set: ${error?.message}`);
  }

  if (planSetRow.linked_exercise_set_id) {
    return {
      exerciseName: planSetRow.training_plan_exercises.exercise_name,
      setIndex: planSetRow.set_index,
      summaryText: `${actualWeight ?? "体重"}${actualWeight != null ? actualWeightUnit : ""} × ${actualReps}`,
    };
  }

  let sessionId: string;
  const { data: existingSession } = await supabase
    .from("workout_sessions")
    .select("id")
    .eq("user_id", userId)
    .eq("workout_date", today)
    .is("deleted_at", null)
    .limit(1)
    .maybeSingle();

  if (existingSession) {
    sessionId = existingSession.id;
  } else {
    const { data: newSession, error: newSessionError } = await supabase
      .from("workout_sessions")
      .insert({
        user_id: userId,
        workout_date: today,
        source_type: "plan",
        parse_status: "completed",
        confirmation_status: "confirmed",
      })
      .select("id")
      .single();
    if (newSessionError || !newSession) {
      throw new Error(`Failed to create workout session for planned set: ${newSessionError?.message}`);
    }
    sessionId = newSession.id;
  }

  const exerciseName = planSetRow.training_plan_exercises.exercise_name;
  let exerciseId: string;
  const { data: existingExercise } = await supabase
    .from("exercises")
    .select("id")
    .eq("session_id", sessionId)
    .eq("name", exerciseName)
    .is("deleted_at", null)
    .limit(1)
    .maybeSingle();

  if (existingExercise) {
    exerciseId = existingExercise.id;
  } else {
    const { data: currentMax } = await supabase
      .from("exercises")
      .select("order_index")
      .eq("session_id", sessionId)
      .order("order_index", { ascending: false })
      .limit(1);
    const nextOrder = currentMax?.[0]?.order_index != null ? currentMax[0].order_index + 1 : 0;
    const { data: newExercise, error: newExerciseError } = await supabase
      .from("exercises")
      .insert({
        session_id: sessionId,
        user_id: userId,
        name: exerciseName,
        normalized_name: exerciseName.toLowerCase().trim(),
        order_index: nextOrder,
      })
      .select("id")
      .single();
    if (newExerciseError || !newExercise) {
      throw new Error(`Failed to create planned exercise row: ${newExerciseError?.message}`);
    }
    exerciseId = newExercise.id;
  }

  const { data: insertedSet, error: insertedSetError } = await supabase
    .from("exercise_sets")
    .insert({
      exercise_id: exerciseId,
      user_id: userId,
      set_index: planSetRow.set_index,
      weight: actualWeight,
      weight_unit: actualWeightUnit,
      reps: actualReps,
    })
    .select("id")
    .single();

  if (insertedSetError || !insertedSet) {
    throw new Error(`Failed to create completed exercise set: ${insertedSetError?.message}`);
  }

  await supabase
    .from("training_plan_sets")
    .update({
      completed_at: new Date().toISOString(),
      linked_exercise_set_id: insertedSet.id,
    })
    .eq("id", planSetId)
    .eq("user_id", userId);

  return {
    exerciseName,
    setIndex: planSetRow.set_index,
    summaryText: `${actualWeight ?? "体重"}${actualWeight != null ? actualWeightUnit : ""} × ${actualReps}`,
  };
}

function toContentPlanDay(day: StoredTrainingPlanDay): ContentBlockPlanDay {
  return {
    plan_day_id: day.id,
    plan_date: day.plan_date,
    day_index: day.day_index,
    title: day.title,
    focus: day.focus ?? null,
    status: day.status,
    exercises: [...(day.training_plan_exercises ?? [])]
      .sort((a, b) => a.order_index - b.order_index)
      .map((exercise) => ({
        plan_exercise_id: exercise.id,
        order_index: exercise.order_index,
        exercise_name: exercise.exercise_name,
        progression_mode: exercise.progression_mode,
        notes: exercise.notes ?? null,
        sets: [...(exercise.training_plan_sets ?? [])]
          .sort((a, b) => a.set_index - b.set_index)
          .map((set) => ({
            plan_set_id: set.id,
            set_index: set.set_index,
            target_weight: set.target_weight,
            target_weight_unit: set.target_weight_unit,
            target_reps: set.target_reps,
            completed_at: set.completed_at ?? null,
            linked_exercise_set_id: set.linked_exercise_set_id ?? null,
          })),
      })),
  };
}

function weeklyPlanContentBlockFromPlan(
  plan: StoredTrainingPlan,
  goalSummary: string | null,
): ContentBlockWeeklyPlan {
  const days = [...(plan.training_plan_days ?? [])]
    .sort((a, b) => a.day_index - b.day_index)
    .map(toContentPlanDay);

  return {
    type: "weekly_plan",
    plan_id: plan.id,
    week_start_date: plan.week_start_date,
    goal_summary: goalSummary ?? plan.goal_snapshot ?? null,
    coach_summary: plan.coach_summary,
    days,
  };
}

function todayPlanContentBlockFromPlan(
  plan: StoredTrainingPlan,
  today: string,
  goalSummary: string | null,
): ContentBlockTodayPlan | null {
  const day = (plan.training_plan_days ?? []).find((item) => item.plan_date === today);
  if (!day) return null;
  return {
    type: "today_plan",
    plan_id: plan.id,
    goal_summary: goalSummary ?? plan.goal_snapshot ?? null,
    day: toContentPlanDay(day),
  };
}

function buildWeeklyPlanAssistantResult({
  reply,
  goalSummary,
  coachSummary,
  plan,
  today,
}: {
  reply: string;
  goalSummary: string | null;
  coachSummary: string;
  plan: StoredTrainingPlan;
  today: string;
}): AssistantToolResult {
  const blocks: ContentBlock[] = [
    { type: "text", text: reply },
    weeklyPlanContentBlockFromPlan(plan, goalSummary),
  ];
  const todayBlock = todayPlanContentBlockFromPlan(plan, today, goalSummary);
  if (todayBlock) {
    blocks.push(todayBlock);
    blocks.push(...buildTodayPlanGuidanceBlocks(todayBlock));
  }
  blocks.push({
    type: "plan_adjustment_summary",
    summary_text: coachSummary,
  });
  return { contentBlocks: blocks };
}

function buildTodayPlanGuidanceBlocks(todayBlock: ContentBlockTodayPlan): ContentBlock[] {
  const firstExercise = todayBlock.day.exercises[0];
  if (!firstExercise) return [];

  const suggestion = firstExercise.progression_mode === "reps_first"
    ? `如果 ${firstExercise.exercise_name} 今天状态稳定，可以把最后两组各加 1 次。`
    : firstExercise.progression_mode === "maintain"
    ? `今天先保持 ${firstExercise.exercise_name} 当前负荷，优先保证动作质量和节奏。`
    : `如果 ${firstExercise.exercise_name} 前两组完成得比较轻松，可以把后两组各加 2.5kg。`;

  return [
    {
      type: "quick_action",
      id: `${firstExercise.plan_exercise_id}-adjust`,
      title: firstExercise.progression_mode === "reps_first" ? "后两组各加 1 次" : "后两组微增负荷",
      prompt: firstExercise.progression_mode === "reps_first"
        ? `把${firstExercise.exercise_name}后两组各加1次`
        : `把${firstExercise.exercise_name}后两组各加2.5kg`,
    },
    {
      type: "exercise_insight",
      exercise_name: firstExercise.exercise_name,
      suggestion,
    },
  ];
}

async function fetchRecentSavedRecordSummariesFromSessions(
  supabase: any,
  userId: string,
): Promise<RecentSavedRecordSummary[]> {
  const { data, error } = await supabase
    .from("workout_sessions")
    .select("id, workout_date, exercises(name, exercise_sets(weight, weight_unit, reps))")
    .eq("user_id", userId)
    .is("deleted_at", null)
    .order("workout_date", { ascending: false })
    .limit(3);

  if (error) {
    throw new Error(`Failed to fetch recent workout sessions: ${error.message}`);
  }

  return (data as RecentSessionRow[] ?? []).map((session) => ({
    workoutSessionId: session.id,
    workoutDate: session.workout_date,
    summaryText: summarizeSessionRow(session),
  }));
}

function summarizeSessionRow(session: RecentSessionRow): string {
  const exercises = Array.isArray(session.exercises) ? session.exercises : [];
  if (exercises.length === 0) {
    return `Workout on ${session.workout_date}`;
  }

  return exercises.slice(0, 3).map((exercise) => {
    const sets = Array.isArray(exercise.exercise_sets) ? exercise.exercise_sets : [];
    const reps = sets[0]?.reps != null ? `${sets[0].reps} reps` : "sets";
    const heaviestWeight = sets.reduce<number | null>((best, set) => {
      if (typeof set.weight !== "number") return best;
      if (best == null || set.weight > best) return set.weight;
      return best;
    }, null);
    const weightUnit = sets.find((set) => typeof set.weight === "number")?.weight_unit ?? "kg";
    const weightText = heaviestWeight != null ? ` @ ${heaviestWeight}${weightUnit}` : "";
    return `${exercise.name} ${sets.length}x${reps}${weightText}`;
  }).join("; ");
}

async function fetchExercisePRMap(
  supabase: any,
  userId: string,
): Promise<Map<string, PRSnapshot>> {
  const { data, error } = await supabase
    .from("exercise_prs")
    .select("normalized_name, display_name, max_weight, weight_unit")
    .eq("user_id", userId);

  if (error) {
    throw new Error(`Failed to fetch exercise PRs: ${error.message}`);
  }

  const result = new Map<string, PRSnapshot>();
  for (const row of data ?? []) {
    result.set(row.normalized_name, {
      displayName: row.display_name,
      maxWeight: Number(row.max_weight),
      weightUnit: row.weight_unit,
    });
  }
  return result;
}

async function safeFetchExercisePRMap(
  supabase: any,
  userId: string,
): Promise<Map<string, PRSnapshot>> {
  try {
    return await fetchExercisePRMap(supabase, userId);
  } catch (error) {
    console.warn("exercise_prs unavailable, skipping PR fetch", error);
    return new Map<string, PRSnapshot>();
  }
}

async function safeRefreshExercisePRs(
  supabase: any,
  userId: string,
): Promise<boolean> {
  const { error } = await supabase.rpc("refresh_exercise_prs_for_user", { v_user_id: userId });
  if (error) {
    console.warn("exercise PR refresh unavailable, skipping PR summary", error);
    return false;
  }
  return true;
}
