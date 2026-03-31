import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  getSupabaseAdminClientKey,
  getSupabaseUserClientKey,
} from "./env.ts";
import {
  createAgentSystemPrompt,
  createWorkoutAgent,
  type WorkoutAgentMessage,
} from "./agent.ts";
import {
  buildPRSummaryBlock,
  buildPRSummary,
  type PRCandidateExercise,
  type PRSummaryItem,
  type PRSnapshot,
} from "./pr-summary.ts";
import {
  pickWorkoutSessionDate,
  type AdjustCurrentOrNextWeekPlanToolInput,
  type CommitWorkoutToolInput,
  type CreateOrRefreshWeeklyPlanToolInput,
  type LogPlannedSetCompletionToolInput,
  type RecentSavedRecordSummary,
  type TrainingPlanDayInput,
  type UpdateProfileGoalToolInput,
} from "./schema.ts";
import {
  streamablePlanContentBlocksFromAssistantToolResult,
  workoutContentBlockFromCommitToolInput,
} from "./stream-events.ts";
import { createChatSSEStream } from "./streaming.ts";
import {
  ADJUST_CURRENT_OR_NEXT_WEEK_PLAN_TOOL_NAME,
  COMMIT_WORKOUT_TOOL_NAME,
  CREATE_OR_REFRESH_WEEKLY_PLAN_TOOL_NAME,
  LOG_PLANNED_SET_COMPLETION_TOOL_NAME,
  UPDATE_PROFILE_GOAL_TOOL_NAME,
} from "./tools.ts";

const PLAN_TOOL_NAMES = new Set([
  CREATE_OR_REFRESH_WEEKLY_PLAN_TOOL_NAME,
  ADJUST_CURRENT_OR_NEXT_WEEK_PLAN_TOOL_NAME,
  LOG_PLANNED_SET_COMPLETION_TOOL_NAME,
  UPDATE_PROFILE_GOAL_TOOL_NAME,
]);

// ============================================================
// Stream event parsing
// ============================================================

/**
 * Parsed representation of a `fullStream` part from the AI SDK.
 *
 * Field names are normalised to what AI SDK v6 emits on `TextStreamPart`:
 * - text-delta      → { text }
 * - tool-input-start → { toolName, id }   (note: SDK v6 uses `id`, not `toolCallId`)
 * - tool-input-delta → { id, delta }       (note: no `toolName`; matched by id)
 * - tool-call        → { toolName, input }
 *
 * All compat fallbacks (inputTextDelta, argsTextDelta, toolCallId) are kept inside
 * this function so the call-site switch is clean and future renames break here only.
 */
type ParsedStreamPart =
  | { kind: "text-delta"; text: string }
  | { kind: "tool-input-start"; toolName: string; id: string }
  | { kind: "tool-input-delta"; id: string; delta: string }
  | { kind: "tool-call"; toolName: string; input: unknown }
  | { kind: "ignored" };

function parseStreamPart(part: unknown): ParsedStreamPart {
  if (typeof part !== "object" || part === null) return { kind: "ignored" };
  const p = part as Record<string, unknown>;
  switch (p.type) {
    case "text-delta":
      return { kind: "text-delta", text: typeof p.text === "string" ? p.text : "" };
    case "tool-input-start":
      return {
        kind: "tool-input-start",
        toolName: typeof p.toolName === "string" ? p.toolName : "",
        // v6 uses `id`; keep `toolCallId` as legacy fallback
        id: typeof p.id === "string" ? p.id : typeof p.toolCallId === "string" ? p.toolCallId : "",
      };
    case "tool-input-delta":
      return {
        kind: "tool-input-delta",
        id: typeof p.id === "string" ? p.id : typeof p.toolCallId === "string" ? p.toolCallId : "",
        // v6 uses `delta`; keep inputTextDelta / argsTextDelta as legacy fallbacks
        delta: typeof p.delta === "string"
          ? p.delta
          : typeof p.inputTextDelta === "string"
          ? p.inputTextDelta
          : typeof p.argsTextDelta === "string"
          ? p.argsTextDelta
          : "",
      };
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

// ============================================================
// Types
// ============================================================

interface RequestBody {
  conversation_id: string;
  text: string;
  client_message_id?: string;
  access_token?: string;
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

type ContentBlock =
  | ContentBlockText
  | ContentBlockWorkoutRecord
  | ContentBlockPRSummary
  | ContentBlockWeeklyPlan
  | ContentBlockTodayPlan
  | ContentBlockPlanAdjustmentSummary;

interface BuildWorkoutResult {
  contentBlocks: ContentBlock[];
  prSummaryBlock?: ContentBlockPRSummary;
}

interface AssistantToolResult {
  contentBlocks: ContentBlock[];
}

interface StoredWorkoutRecordBlock {
  type: "workout_record";
  workout_session_id: string;
  workout_date: string;
  exercises?: Array<{
    name?: string;
    sets?: Array<{
      weight?: number | null;
      weight_unit?: string;
      reps?: number | null;
    }>;
  }>;
}

// ============================================================
// Main handler
// ============================================================

Deno.serve(async (req: Request) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
      },
    });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseUserKey = getSupabaseUserClientKey(Deno.env.toObject());
  const supabaseAdminKey = getSupabaseAdminClientKey(Deno.env.toObject());
  const deepseekApiKey = Deno.env.get("DEEPSEEK_API_KEY");

  if (!supabaseUrl || !supabaseUserKey || !supabaseAdminKey || !deepseekApiKey?.trim()) {
    console.error("Missing Supabase function config", {
      hasUrl: Boolean(supabaseUrl),
      hasUserKey: Boolean(supabaseUserKey),
      hasAdminKey: Boolean(supabaseAdminKey),
      hasDeepseek: Boolean(deepseekApiKey?.trim()),
    });

    return new Response(JSON.stringify({
      error: "Function misconfigured: missing Supabase runtime keys or DEEPSEEK_API_KEY",
    }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  // ── Parse request body ────────────────────────────────────
  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const { conversation_id, text, client_message_id, access_token } = body;
  if (!conversation_id || !text?.trim()) {
    return new Response(JSON.stringify({ error: "conversation_id and text are required" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const authHeader = req.headers.get("Authorization") ?? req.headers.get("authorization");
  const bearerToken = authHeader?.startsWith("Bearer ") ? authHeader.slice("Bearer ".length) : authHeader;
  const userAccessToken = bearerToken ?? access_token;
  if (!userAccessToken) {
    return new Response(JSON.stringify({ error: "Missing access token" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  // User-scoped client (for RLS-respecting reads)
  const supabaseUser = createClient(supabaseUrl, supabaseUserKey, {
    global: { headers: { Authorization: `Bearer ${userAccessToken}` } },
  });

  // Service-role client (for writing without RLS restrictions in edge function context)
  const supabaseAdmin = createClient(supabaseUrl, supabaseAdminKey);

  // Verify JWT and get user
  const { data: { user }, error: authError } = await supabaseUser.auth.getUser(userAccessToken);
  if (authError || !user) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Verify conversation belongs to user
  const { data: conv, error: convError } = await supabaseAdmin
    .from("conversations")
    .select("id")
    .eq("id", conversation_id)
    .eq("user_id", user.id)
    .single();

  if (convError || !conv) {
    return new Response(JSON.stringify({ error: "Conversation not found" }), {
      status: 404,
      headers: { "Content-Type": "application/json" },
    });
  }

  // ── Insert user message ───────────────────────────────────
  const messagePayload = {
    conversation_id,
    user_id: user.id,
    role: "user",
    content: text.trim(),
    content_blocks: [{ type: "text", text: text.trim() }],
    status: "completed",
    parse_status: "completed",
    client_message_id: client_message_id ?? null,
    input_type: "text",
  };

  let userMsg:
    | { id: string }
    | null = null;

  if (client_message_id) {
    const { data: existingMessage, error: existingMessageError } = await supabaseAdmin
      .from("messages")
      .select("id")
      .eq("user_id", user.id)
      .eq("conversation_id", conversation_id)
      .eq("client_message_id", client_message_id)
      .maybeSingle();

    if (existingMessageError) {
      console.error("Failed to look up existing user message:", existingMessageError);
      return new Response(JSON.stringify({ error: "Failed to save message" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    userMsg = existingMessage;
  }

  const { data: insertedUserMsg, error: userMsgError } = userMsg
    ? { data: userMsg, error: null }
    : await supabaseAdmin
      .from("messages")
      .insert(messagePayload)
      .select("id")
      .single();

  if (userMsgError) {
    console.error("Failed to insert user message:", userMsgError);
    return new Response(JSON.stringify({ error: "Failed to save message" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const savedUserMsg = insertedUserMsg;
  if (!savedUserMsg) {
    return new Response(JSON.stringify({ error: "Failed to save message" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Generate a stable ID for the assistant message.
  // The row is written once to DB after the stream completes (no placeholder needed).
  const assistantMessageId = crypto.randomUUID();

  const sseBody = createChatSSEStream(async ({ send, isClosed }) => {
      const {
        contextMessages,
        today,
        recentSavedRecords,
        profileGoalSummary,
        activeWeeklyPlanSummary,
        todayPlanSummary,
        recentPlanAdherenceSummary,
      } = await loadConversationContextForAgent(
        supabaseAdmin,
        user.id,
        conversation_id,
      );

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
          try {
            const commitResult = await persistCommitWorkoutInTool({
              supabaseAdmin,
              userId: user.id,
              sourceMessageId: savedUserMsg.id,
              parsed,
              today,
            });
            assistantToolResult = { contentBlocks: commitResult.contentBlocks };
          } catch (error) {
            console.error("commit_workout persistence failed", {
              conversationId: conversation_id,
              userId: user.id,
              sourceMessageId: savedUserMsg.id,
              assistantMessageId,
              error,
            });
            throw error;
          }
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
            sourceMessageId: savedUserMsg.id,
            parsed,
            today,
          });
        },
        onAdjustCurrentOrNextWeekPlan: async (parsed) => {
          assistantToolResult = await persistWeeklyPlanAdjustmentInTool({
            supabaseAdmin,
            userId: user.id,
            sourceMessageId: savedUserMsg.id,
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
        messages: [
          ...contextMessages.filter((m) => m.content.trim().length > 0),
          { role: "user" as const, content: text.trim() },
        ],
      });

      send({ type: "status", phase: "processing" });

      // Track the active commit tool call by id (tool-input-delta has no toolName in SDK v6).
      let commitToolCallId: string | null = null;
      // Accumulate text for the pure-text reply path (no tool call).
      let accumulatedText = "";
      let sawAnyToolCall = false;

      try {
        for await (const part of streamResult.fullStream) {
          if (isClosed()) {
            break;
          }
          const parsed = parseStreamPart(part);
          switch (parsed.kind) {
            case "text-delta":
              accumulatedText += parsed.text;
              if (parsed.text.length > 0) {
                send({ type: "text-delta", textDelta: parsed.text });
              }
              break;
            case "tool-input-start":
              if (parsed.toolName === COMMIT_WORKOUT_TOOL_NAME) {
                commitToolCallId = parsed.id;
                send({ type: "workout-block-stream-start", toolCallId: parsed.id });
              }
              break;
            case "tool-input-delta":
              // Forward delta only while a commit tool call is active.
              // id-based matching handles agents with multiple tools.
              if (commitToolCallId !== null && parsed.delta.length > 0) {
                send({ type: "workout-block-delta", textDelta: parsed.delta });
              }
              break;
            case "tool-call":
              sawAnyToolCall = true;
              if (parsed.toolName === COMMIT_WORKOUT_TOOL_NAME) {
                const block = workoutContentBlockFromCommitToolInput(
                  parsed.input,
                  { fallbackDate: today },
                  "preview",
                );
                if (block) {
                  send({ type: "workout-content-block", block });
                }
              } else if (PLAN_TOOL_NAMES.has(parsed.toolName)) {
                send({ type: "status", phase: "applying" });
              }
              break;
          }
        }

        // Post-stream DB write — single INSERT with final content.
        const baseFields = {
          id: assistantMessageId,
          conversation_id,
          user_id: user.id,
          role: "assistant",
          input_type: "text",
        };

        if (assistantToolResult !== null) {
          const assistantText = (assistantToolResult.contentBlocks[0] as ContentBlockText | undefined)?.text ?? "";
          await supabaseAdmin.from("messages").insert({
            ...baseFields,
            content: assistantText || null,
            content_blocks: assistantToolResult.contentBlocks,
            status: "completed",
            parse_status: "completed",
          });
          for (const block of streamablePlanContentBlocksFromAssistantToolResult(assistantToolResult)) {
            send({ type: "plan-content-block", block });
          }
          send({ type: "status", phase: "completed" });
        } else if (sawAnyToolCall) {
          await supabaseAdmin.from("messages").insert({
            ...baseFields,
            content: "处理你的计划或训练请求失败，请稍后再试。",
            content_blocks: [{ type: "text", text: "处理你的计划或训练请求失败，请稍后再试。" }],
            status: "failed",
            parse_status: "failed",
          });
          send({ type: "status", phase: "failed" });
        } else {
          // Pure text reply path.
          const content = accumulatedText.trim();
          await supabaseAdmin.from("messages").insert({
            ...baseFields,
            content: content || null,
            content_blocks: content ? [{ type: "text", text: content }] : null,
            status: "completed",
            parse_status: "completed",
          });
          send({ type: "status", phase: "completed" });
        }

        send({ type: "done" });
      } catch (streamErr) {
        console.error("SSE forward error:", streamErr);
        // Sanitise: never expose internal stack traces to the client.
        send({ type: "error", message: "Stream error occurred. Please try again." });
        send({ type: "status", phase: "failed" });
        try {
          await supabaseAdmin.from("messages").insert({
            id: assistantMessageId,
            conversation_id,
            user_id: user.id,
            role: "assistant",
            input_type: "text",
            content: "Sorry, I had trouble processing that. Please try again.",
            content_blocks: [{
              type: "text",
              text: "Sorry, I had trouble processing that. Please try again.",
            }],
            status: "failed",
            parse_status: "failed",
          });
        } catch (dbErr) {
          console.error("Failed to insert assistant message after stream error:", dbErr);
        }
      }
  });

  return new Response(sseBody, {
    status: 200,
    headers: {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      "Connection": "keep-alive",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Expose-Headers": "X-User-Message-Id, X-Assistant-Message-Id",
      "X-User-Message-Id": savedUserMsg.id,
      "X-Assistant-Message-Id": assistantMessageId,
    },
  });
});

// ============================================================
// Agent context
// ============================================================

async function loadConversationContextForAgent(
  supabaseAdmin: any,
  userId: string,
  conversationId: string,
): Promise<{
  contextMessages: WorkoutAgentMessage[];
  today: string;
  recentSavedRecords: RecentSavedRecordSummary[];
  profileGoalSummary: string | null;
  activeWeeklyPlanSummary: string;
  todayPlanSummary: string;
  recentPlanAdherenceSummary: string;
}> {
  const recentMessageLimit = 16;
  const { data: recentMessages } = await supabaseAdmin
    .from("messages")
    .select("role, content")
    .eq("conversation_id", conversationId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .order("created_at", { ascending: false })
    .limit(recentMessageLimit);

  const contextMessages = (recentMessages ?? [])
    .reverse()
    .filter((m: any) => m.content)
    .map((m: any) => ({ role: m.role as "user" | "assistant", content: m.content as string }));

  const today = new Date().toISOString().split("T")[0];
  const recentSavedRecords = await fetchRecentSavedRecordSummaries(
    supabaseAdmin,
    userId,
    conversationId,
  );
  const profileGoalSummary = await fetchProfileGoalSummary(supabaseAdmin, userId);
  const activePlan = await fetchActiveWeeklyPlan(supabaseAdmin, userId);
  const activeWeeklyPlanSummary = summarizeWeeklyPlan(activePlan);
  const todayPlanSummary = summarizeTodayPlan(activePlan, today);
  const recentPlanAdherenceSummary = await summarizeRecentPlanAdherence(supabaseAdmin, userId);

  return {
    contextMessages,
    today,
    recentSavedRecords,
    profileGoalSummary,
    activeWeeklyPlanSummary,
    todayPlanSummary,
    recentPlanAdherenceSummary,
  };
}

/** Runs inside `commit_workout` tool `execute` — inserts workout rows and returns content blocks.
 *  The caller is responsible for writing the assistant message to DB after the stream finishes. */
async function persistCommitWorkoutInTool({
  supabaseAdmin,
  userId,
  sourceMessageId,
  parsed,
  today,
}: {
  supabaseAdmin: any;
  userId: string;
  sourceMessageId: string;
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
  sourceMessageId: string;
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
  sourceMessageId: string;
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
    const weeklyBlock = weeklyPlanContentBlockFromPlan(activePlan, goalSummary);
    blocks.push(weeklyBlock);
    const todayBlock = todayPlanContentBlockFromPlan(activePlan, today, goalSummary);
    if (todayBlock) {
      blocks.push(todayBlock);
    }
  }
  blocks.push({
    type: "plan_adjustment_summary",
    summary_text: `已记录 ${completion.exerciseName} 第 ${completion.setIndex} 组：${completion.summaryText}`,
  });
  return { contentBlocks: blocks };
}

// ============================================================
// Build workout rows + content_blocks
// ============================================================

async function buildWorkoutAndContentBlocks(
  supabase: any,
  userId: string,
  sourceMessageId: string,
  parsed: CommitWorkoutToolInput,
  fallbackDate: string,
): Promise<BuildWorkoutResult> {
  const blocks: ContentBlock[] = [
    { type: "text", text: parsed.reply },
  ];

  const exercises = parsed.exercises ?? [];
  if (exercises.length === 0) {
    return { contentBlocks: blocks };
  }

  const workoutDate = pickWorkoutSessionDate(parsed.workoutDate, fallbackDate);
  const previousPRs = await safeFetchExercisePRMap(supabase, userId);

  // Check if there's already a session for this user+date (append mode)
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
        source_message_id: sourceMessageId,
        workout_date: workoutDate,
        source_type: "chat",
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

  // Get current max order_index for appending
  const { data: existingExercises } = await supabase
    .from("exercises")
    .select("order_index")
    .eq("session_id", sessionId)
    .is("deleted_at", null)
    .order("order_index", { ascending: false })
    .limit(1);

  let orderOffset = existingExercises?.[0]?.order_index != null
    ? existingExercises[0].order_index + 1
    : 0;

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

  for (const parsedEx of exercises) {
    // Insert exercise
    const { data: exerciseRow, error: exError } = await supabase
      .from("exercises")
      .insert({
        session_id: sessionId,
        user_id: userId,
        name: parsedEx.name,
        normalized_name: parsedEx.name.toLowerCase().trim(),
        order_index: orderOffset++,
      })
      .select()
      .single();

    const insertedExercise = exerciseRow as InsertedExerciseRow | null;

    if (exError || !insertedExercise) {
      throw new Error(`Failed to insert exercise: ${exError?.message}`);
    }

    // Insert sets
    const setRows = parsedEx.sets.map((s) => ({
      exercise_id: exerciseRow.id,
      user_id: userId,
      set_index: s.setIndex,
      weight: s.weight ?? null,
      weight_unit: s.weightUnit ?? "kg",
      reps: s.reps ?? null,
    }));

    const { data: insertedSets, error: setsError } = await supabase
      .from("exercise_sets")
      .insert(setRows)
      .select();

    const createdSets = (insertedSets ?? []) as InsertedSetRow[];

    if (setsError || !insertedSets) {
      throw new Error(`Failed to insert exercise_sets: ${setsError?.message}`);
    }

    const maxSet = createdSets.reduce((best, current) => {
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
      sets: createdSets.map((s) => ({
        set_id: s.id,
        set_index: s.set_index,
        weight: s.weight,
        weight_unit: s.weight_unit,
        reps: s.reps,
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
  let prSummaryBlock: ContentBlockPRSummary | undefined;
  if (prRefreshAvailable) {
    const currentPRs = await safeFetchExercisePRMap(supabase, userId);
    const prSummary = buildPRSummary({
      previousPRs,
      currentPRs,
      candidateExercises,
    });
    prSummaryBlock = buildPRSummaryBlock(prSummary) ?? undefined;
    if (prSummaryBlock) {
      blocks.push(prSummaryBlock);
    }
  }

  return {
    contentBlocks: blocks,
    prSummaryBlock,
  };
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

async function fetchProfileGoalSummary(
  supabase: any,
  userId: string,
): Promise<string | null> {
  const { data } = await supabase
    .from("profiles")
    .select("fitness_goal_summary")
    .eq("id", userId)
    .maybeSingle();

  return typeof data?.fitness_goal_summary === "string" ? data.fitness_goal_summary : null;
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
  return `${day.title} (${day.status}): ${
    exercises.map((exercise) => exercise.exercise_name).join(", ")
  }`;
}

async function summarizeRecentPlanAdherence(
  supabase: any,
  userId: string,
): Promise<string> {
  const { data, error } = await supabase
    .from("training_plans")
    .select(
      "id, week_start_date, training_plan_days(id, training_plan_exercises(id, training_plan_sets(id, completed_at)))",
    )
    .eq("user_id", userId)
    .order("week_start_date", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error || !data) {
    return "No adherence data yet.";
  }

  const days = data.training_plan_days ?? [];
  let totalSets = 0;
  let completedSets = 0;
  for (const day of days) {
    for (const exercise of day.training_plan_exercises ?? []) {
      for (const set of exercise.training_plan_sets ?? []) {
        totalSets += 1;
        if (set.completed_at) completedSets += 1;
      }
    }
  }

  if (totalSets === 0) {
    return "No adherence data yet.";
  }

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
  sourceMessageId: string;
  weekStartDate: string;
  coachSummary: string;
  days: TrainingPlanDayInput[];
  goalSummary: string | null;
}): Promise<StoredTrainingPlan> {
  await supabase
    .from("training_plans")
    .update({ status: "archived" })
    .eq("user_id", userId)
    .eq("status", "active");

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
        source_message_id: sourceMessageId,
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
        source_message_id: sourceMessageId,
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
  }
  blocks.push({
    type: "plan_adjustment_summary",
    summary_text: coachSummary,
  });
  return { contentBlocks: blocks };
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
    .select("id, set_index, target_weight, target_weight_unit, target_reps, linked_exercise_set_id, plan_exercise_id, training_plan_exercises!inner(id, exercise_name)")
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

async function fetchRecentSavedRecordSummaries(
  supabase: any,
  userId: string,
  conversationId: string,
): Promise<RecentSavedRecordSummary[]> {
  const { data, error } = await supabase
    .from("messages")
    .select("id, content_blocks")
    .eq("conversation_id", conversationId)
    .eq("user_id", userId)
    .eq("role", "assistant")
    .is("deleted_at", null)
    .order("created_at", { ascending: false })
    .limit(12);

  if (error) {
    throw new Error(`Failed to fetch recent saved workout records: ${error.message}`);
  }

  const summaries: RecentSavedRecordSummary[] = [];

  for (const row of data ?? []) {
    const contentBlocks = Array.isArray(row.content_blocks) ? row.content_blocks as StoredWorkoutRecordBlock[] : [];
    const workoutRecord = contentBlocks.find((block) => block?.type === "workout_record");
    if (!workoutRecord?.workout_session_id || !workoutRecord.workout_date) {
      continue;
    }

    summaries.push({
      workoutSessionId: workoutRecord.workout_session_id,
      workoutDate: workoutRecord.workout_date,
      summaryText: summarizeWorkoutRecord(workoutRecord),
      sourceMessageId: row.id,
    });

    if (summaries.length >= 3) {
      break;
    }
  }

  return summaries;
}

function summarizeWorkoutRecord(record: StoredWorkoutRecordBlock): string {
  const exercises = Array.isArray(record.exercises) ? record.exercises : [];
  if (exercises.length === 0) {
    return `Workout on ${record.workout_date}`;
  }

  return exercises
    .slice(0, 3)
    .map((exercise) => {
      const sets = Array.isArray(exercise.sets) ? exercise.sets : [];
      const reps = sets[0]?.reps != null ? `${sets[0].reps} reps` : "sets";
      const heaviestWeight = sets.reduce<number | null>((best, set) => {
        if (typeof set.weight !== "number") {
          return best;
        }
        if (best == null || set.weight > best) {
          return set.weight;
        }
        return best;
      }, null);
      const weightUnit = sets.find((set) => typeof set.weight === "number")?.weight_unit ?? "kg";
      const weightText = heaviestWeight != null ? ` @ ${heaviestWeight}${weightUnit}` : "";
      return `${exercise.name ?? "Exercise"} ${sets.length}x${reps}${weightText}`;
    })
    .join("; ");
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
