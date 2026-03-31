import {
  aiWorkoutActionRequestSchema,
  buildAIWorkoutActionResponse,
} from "../supabase/functions/ai-workout-action/helpers.ts";

Deno.test("ai workout action request schema accepts text with optional target date", () => {
  const parsed = aiWorkoutActionRequestSchema.safeParse({
    text: "把今天的卧推改成 55kg 4x6",
    targetDate: "2026-03-30",
  });

  if (!parsed.success) {
    throw new Error(`Expected request schema to accept valid payload: ${parsed.error.message}`);
  }
});

Deno.test("ai workout action response derives reply and refresh flag from returned content blocks", () => {
  const response = buildAIWorkoutActionResponse({
    contentBlocks: [
      { type: "text", text: "我已经把今天的卧推调整成 55kg 4x6。" },
      { type: "today_plan", plan_id: "plan-1", goal_summary: null, day: {
        plan_day_id: "day-1",
        plan_date: "2026-03-30",
        day_index: 1,
        title: "Push Day",
        focus: "胸肩三头",
        status: "planned",
        exercises: [],
      } },
    ],
  });

  if (response.reply !== "我已经把今天的卧推调整成 55kg 4x6。") {
    throw new Error("Expected text block to become top-level reply");
  }

  if (!response.requiresTodayRefresh) {
    throw new Error("Expected today plan content to request a page refresh");
  }
});

Deno.test("ai workout action response exposes quick actions and exercise insights", () => {
  const response = buildAIWorkoutActionResponse({
    contentBlocks: [
      { type: "text", text: "这次卧推状态不错。" },
      {
        type: "quick_action",
        id: "load-up",
        title: "后两组加 2.5kg",
        prompt: "把卧推后两组加 2.5kg",
      },
      {
        type: "exercise_insight",
        exercise_name: "Bench Press",
        previous_performance_summary: "上次：70kg × 5",
        suggestion: "如果本组 RPE ≤ 8，可以加 2.5kg。",
      },
    ],
  });

  if (response.quickActions.length !== 1) {
    throw new Error("Expected quick action blocks to be promoted to top-level quickActions");
  }

  if (response.exerciseInsights[0]?.previousPerformanceSummary !== "上次：70kg × 5") {
    throw new Error("Expected exercise insight summary to be promoted to top-level exerciseInsights");
  }
});
