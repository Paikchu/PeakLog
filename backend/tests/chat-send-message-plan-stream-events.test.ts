import test from "node:test";
import assert from "node:assert/strict";
import {
  streamablePlanContentBlocksFromAssistantToolResult,
} from "../supabase/functions/chat-send-message/stream-events.ts";

test("streamablePlanContentBlocksFromAssistantToolResult keeps only plan-related blocks in order", () => {
  const blocks = streamablePlanContentBlocksFromAssistantToolResult({
    contentBlocks: [
      { type: "text", text: "我已经按你的要求完成调整。" },
      {
        type: "weekly_plan",
        plan_id: "plan-1",
        week_start_date: "2026-03-30",
        goal_summary: "增肌",
        coach_summary: "每周 6 练",
        days: [],
      },
      {
        type: "today_plan",
        plan_id: "plan-1",
        goal_summary: "增肌",
        day: {
          plan_day_id: "day-1",
          plan_date: "2026-03-30",
          day_index: 1,
          title: "Chest + Biceps",
          focus: "胸和二头",
          status: "planned",
          exercises: [],
        },
      },
      {
        type: "plan_adjustment_summary",
        summary_text: "已将本周调整为 6 天训练，肩和手臂增加频次。",
      },
    ],
  });

  assert.deepEqual(
    blocks.map((block) => block.type),
    ["weekly_plan", "today_plan", "plan_adjustment_summary"],
  );
});

test("streamablePlanContentBlocksFromAssistantToolResult ignores workout and text-only results", () => {
  const blocks = streamablePlanContentBlocksFromAssistantToolResult({
    contentBlocks: [
      { type: "text", text: "好的。" },
      {
        type: "workout_record",
        workout_session_id: "session-1",
        workout_date: "2026-03-30",
        title: null,
        parse_status: "completed",
        exercises: [],
      },
    ],
  });

  assert.equal(blocks.length, 0);
});
