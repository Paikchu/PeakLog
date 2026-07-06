import { z } from "../_shared/deps.ts";

export const aiWorkoutActionRequestSchema = z.object({
  text: z.string().trim().min(1),
  targetDate: z.string().optional(),
});

export interface AIWorkoutActionContentBlock {
  type: string;
  [key: string]: unknown;
}

export interface AIWorkoutQuickAction {
  id: string;
  title: string;
  prompt: string;
}

export interface AIWorkoutExerciseInsight {
  exerciseName: string;
  previousPerformanceSummary?: string;
  suggestion?: string;
}

export interface AIWorkoutActionResponse {
  status: "completed" | "clarify";
  reply: string;
  contentBlocks: AIWorkoutActionContentBlock[];
  requiresTodayRefresh: boolean;
  quickActions: AIWorkoutQuickAction[];
  exerciseInsights: AIWorkoutExerciseInsight[];
}

export function buildAIWorkoutActionResponse(
  toolResult: { contentBlocks: AIWorkoutActionContentBlock[] } | null,
  fallbackReply = "",
): AIWorkoutActionResponse {
  const contentBlocks = toolResult?.contentBlocks ?? [];
  const textBlock = contentBlocks.find((block) => block.type === "text" && typeof block.text === "string");
  const reply = (textBlock?.text as string | undefined) ?? fallbackReply;

  const requiresTodayRefresh = contentBlocks.some((block) =>
    block.type === "workout_record" ||
    block.type === "running_record" ||
    block.type === "today_plan" ||
    block.type === "weekly_plan" ||
    block.type === "plan_adjustment_summary"
  );

  const quickActions = contentBlocks.flatMap((block) => {
    if (
      block.type === "quick_action" &&
      typeof block.id === "string" &&
      typeof block.title === "string" &&
      typeof block.prompt === "string"
    ) {
      return [{ id: block.id, title: block.title, prompt: block.prompt }];
    }
    return [];
  });

  const exerciseInsights = contentBlocks.flatMap((block) => {
    if (block.type !== "exercise_insight" || typeof block.exercise_name !== "string") {
      return [];
    }

    return [{
      exerciseName: block.exercise_name,
      previousPerformanceSummary: typeof block.previous_performance_summary === "string"
        ? block.previous_performance_summary
        : undefined,
      suggestion: typeof block.suggestion === "string" ? block.suggestion : undefined,
    }];
  });

  return {
    status: "completed",
    reply,
    contentBlocks,
    requiresTodayRefresh,
    quickActions,
    exerciseInsights,
  };
}
