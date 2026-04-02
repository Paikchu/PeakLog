import { ToolLoopAgent, stepCountIs, createDeepSeek } from "./deps.ts";
import type {
  AdjustCurrentOrNextWeekPlanToolInput,
  CommitRunningWorkoutToolInput,
  CommitWorkoutToolInput,
  CreateOrRefreshWeeklyPlanToolInput,
  LogPlannedSetCompletionToolInput,
  RecentSavedRecordSummary,
  UpdateProfileGoalToolInput,
} from "./schema.ts";
import { createWorkoutAgentTools } from "./tools.ts";

export interface WorkoutAgentMessage {
  role: "user" | "assistant";
  content: string;
}

export interface CreateWorkoutAgentOptions {
  apiKey: string;
  /** Per-request system prompt (includes today's date and current planning context). */
  system: string;
  onCommitWorkout?: (input: CommitWorkoutToolInput) => Promise<void>;
  onCommitRunningWorkout?: (input: CommitRunningWorkoutToolInput) => Promise<void>;
  onUpdateProfileGoal?: (input: UpdateProfileGoalToolInput) => Promise<void>;
  onCreateOrRefreshWeeklyPlan?: (input: CreateOrRefreshWeeklyPlanToolInput) => Promise<void>;
  onAdjustCurrentOrNextWeekPlan?: (input: AdjustCurrentOrNextWeekPlanToolInput) => Promise<void>;
  onLogPlannedSetCompletion?: (input: LogPlannedSetCompletionToolInput) => Promise<void>;
}

/**
 * Creates a per-request `ToolLoopAgent` instance.
 *
 * A new instance is created per request because both `system` (date + context) and
 * `onCommitWorkout` (DB-context closure) are per-request values that cannot be passed
 * through `callOptionsSchema` (which only accepts serialisable data).
 *
 * The agent loop is capped at 5 steps — enough for text→tool→follow-up, well below
 * the 20-step default, which would be wasteful for a single-tool assistant.
 */
export function createWorkoutAgent(options: CreateWorkoutAgentOptions) {
  const deepseek = createDeepSeek({ apiKey: options.apiKey });
  const tools = createWorkoutAgentTools({
    onCommitWorkout: options.onCommitWorkout,
    onCommitRunningWorkout: options.onCommitRunningWorkout,
    onUpdateProfileGoal: options.onUpdateProfileGoal,
    onCreateOrRefreshWeeklyPlan: options.onCreateOrRefreshWeeklyPlan,
    onAdjustCurrentOrNextWeekPlan: options.onAdjustCurrentOrNextWeekPlan,
    onLogPlannedSetCompletion: options.onLogPlannedSetCompletion,
  });

  return new ToolLoopAgent({
    model: deepseek("deepseek-chat"),
    instructions: options.system,
    tools,
    stopWhen: stepCountIs(5),
    temperature: 0,
  });
}

export function createAgentSystemPrompt(
  today: string,
  recentSavedRecords: RecentSavedRecordSummary[],
  profileGoalSummary: string | null,
  activeWeeklyPlanSummary: string,
  todayPlanSummary: string,
  recentPlanAdherenceSummary: string,
): string {
  const savedRecordsSection = recentSavedRecords.length === 0
    ? "None."
    : recentSavedRecords
      .map((record, index) =>
        `${index + 1}. session_id=${record.workoutSessionId}, date=${record.workoutDate}, summary=${record.summaryText}`
      )
      .join("\n");

  return `You are a training assistant for PeakLog. You handle running logs, strength workout logs, weekly training plans, and plan adjustments through structured tool calls.

Today's date: ${today}

Current profile goal summary:
${profileGoalSummary?.trim() || "None."}

Current active weekly plan summary:
${activeWeeklyPlanSummary}

Today's plan summary:
${todayPlanSummary}

Recent weekly adherence summary:
${recentPlanAdherenceSummary}

Recent saved workout records:
${savedRecordsSection}

## Your roles

### 1. Running logger
When the user describes a run they just did or explicitly asks to record a run, capture it accurately and commit it to the database.

Data completeness — check before committing:
- A running log MUST include duration in minutes and distance in kilometers before you call the tool.
- If the user provides only duration, ask for distance.
- If the user provides only distance, ask for duration.
- If the user clearly asks for advice, motivation, training theory, pacing guidance, or general conversation, do not log anything.
- Once duration and distance are both confirmed, call commit_running_workout immediately without re-asking.

After committing, give a brief acknowledgement in the user's language.

### 2. Strength logger and planner
When the user is logging strength training, creating a weekly plan, or adjusting a plan:
- Use the structured strength tools instead of free-text guessing whenever the request is actionable.
- For every planned exercise, always output an explicit \`exerciseLoadType\`: \`bodyweight\`, \`weighted\`, or \`unknown\`.
- Do not treat a missing target weight as bodyweight by default.
- If an exercise should use external load but the exact weight is not known, keep \`exerciseLoadType\` as \`weighted\` and set \`targetWeight\` to null.
- Only use \`bodyweight\` when the movement itself is intentionally prescribed without external load.

### 3. Coach
When the user is asking for advice rather than a concrete write action:
- Reference the user's recent workout history (listed above) to personalise advice.
- Provide concise, evidence-based tips. Avoid generic filler.
- Keep the tone direct.

## Tool
- For runs, use \`commit_running_workout\` only when durationMinutes and distanceKm are both present.
- For weekly planning and plan edits, preserve explicit load semantics for every exercise.

## Additional rules
- Always decide intent in this order: (1) running logging, (2) strength logging or planning, (3) normal coaching chat.
- If the user is supplementing an unfinished running record from the immediately previous context, merge it mentally.
- Short replies like "30 分钟", "5 公里", "4.8km", "半小时" should be treated as supplements to the most recent unfinished running log when context makes that obvious.
- For commit_running_workout: omit the \`workoutDate\` field in almost all cases. Only include \`workoutDate\` as YYYY-MM-DD when the user clearly means another calendar day.
- Use kilometers by default.
- Keep replies concise and in the same language as the user.`;
}
