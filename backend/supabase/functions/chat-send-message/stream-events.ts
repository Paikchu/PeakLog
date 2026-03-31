import { parseCommitWorkoutToolInput, pickWorkoutSessionDate } from "./schema.ts";

/**
 * Set row shape for rendering a workout card from streamed LLM output (before DB assigns UUIDs).
 * `set_id` is empty until the persisted assistant message arrives via Realtime.
 */
export interface WorkoutContentBlockSet {
  set_id: string;
  set_index: number;
  weight: number | null;
  weight_unit: string;
  reps: number | null;
}

/**
 * Exercise row shape for rendering from streamed `commit_workout` tool arguments.
 * `exercise_id` is empty until persistence.
 */
export interface WorkoutContentBlockExercise {
  exercise_id: string;
  name: string;
  order_index: number;
  sets: WorkoutContentBlockSet[];
}

/**
 * Client-facing workout block emitted over SSE when the model streams/finishes `commit_workout` args.
 * Aligns with iOS GenUI expectations: same nesting as persisted `workout_record`, IDs filled after save.
 */
export interface WorkoutContentBlock {
  type: "workout_record_stream";
  workout_date: string;
  title: string | null;
  parse_status: "streaming" | "preview";
  /** Empty during stream; optional hint after tool execute (still prefer Realtime for canonical id). */
  workout_session_id: string;
  exercises: WorkoutContentBlockExercise[];
}

export interface WeeklyPlanStreamBlock {
  type: "weekly_plan";
  plan_id: string;
  week_start_date: string;
  goal_summary: string | null;
  coach_summary: string;
  days: unknown[];
}

export interface TodayPlanStreamBlock {
  type: "today_plan";
  plan_id: string;
  goal_summary: string | null;
  day: unknown;
}

export interface PlanAdjustmentSummaryStreamBlock {
  type: "plan_adjustment_summary";
  summary_text: string;
}

export type StreamablePlanContentBlock =
  | WeeklyPlanStreamBlock
  | TodayPlanStreamBlock
  | PlanAdjustmentSummaryStreamBlock;

export function workoutContentBlockFromCommitToolInput(
  raw: unknown,
  opts: { fallbackDate: string },
  parseStatus: WorkoutContentBlock["parse_status"],
): WorkoutContentBlock | null {
  const parsed = parseCommitWorkoutToolInput(raw);
  if (!parsed.success) {
    return null;
  }
  const workoutDate = pickWorkoutSessionDate(parsed.data.workoutDate, opts.fallbackDate);
  return {
    type: "workout_record_stream",
    workout_date: workoutDate,
    title: null,
    parse_status: parseStatus,
    workout_session_id: "",
    exercises: parsed.data.exercises.map((ex, i) => ({
      exercise_id: "",
      name: ex.name,
      order_index: i,
      sets: ex.sets.map((s) => ({
        set_id: "",
        set_index: s.setIndex,
        weight: s.weight,
        weight_unit: s.weightUnit,
        reps: s.reps,
      })),
    })),
  };
}

export function streamablePlanContentBlocksFromAssistantToolResult(
  result: { contentBlocks?: unknown[] | null },
): StreamablePlanContentBlock[] {
  return (result.contentBlocks ?? []).flatMap((block) => {
    if (typeof block !== "object" || block === null) {
      return [];
    }

    const candidate = block as Record<string, unknown>;
    switch (candidate.type) {
      case "weekly_plan":
      case "today_plan":
      case "plan_adjustment_summary":
        return [candidate as StreamablePlanContentBlock];
      default:
        return [];
    }
  });
}
