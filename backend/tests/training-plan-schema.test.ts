import {
  createOrRefreshWeeklyPlanToolInputSchema,
  parseCreateOrRefreshWeeklyPlanToolInput,
  updateProfileGoalToolInputSchema,
} from "../supabase/functions/_shared/schema.ts";

Deno.test("update_profile_goal schema accepts natural language goal summaries", () => {
  const parsed = updateProfileGoalToolInputSchema.safeParse({
    goalSummary: "目标是增肌，重点提升胸肩和卧推表现，每周训练 4 天。",
    reply: "我已经帮你更新目标，接下来会按增肌优先来安排课表。",
  });

  if (!parsed.success) {
    throw new Error(`Expected update_profile_goal input to parse: ${parsed.error.message}`);
  }
});

Deno.test("create_or_refresh_weekly_plan parser accepts structured week plans", () => {
  const payload = {
    reply: "我已经按你的目标生成了本周计划。",
    weekStartDate: "2026-03-23",
    coachSummary: "本周以推拉腿三分化为主，控制总量并优先保证卧推进展。",
    days: [
      {
        planDate: "2026-03-24",
        dayIndex: 1,
        title: "Push Strength",
        focus: "胸肩三头",
        status: "planned",
        exercises: [
          {
            orderIndex: 0,
            exerciseName: "Bench Press",
            exerciseLoadType: "weighted",
            progressionMode: "weight_first",
            notes: "若全部完成则下周小幅加重",
            sets: [
              { setIndex: 1, targetWeight: 40, targetWeightUnit: "kg", targetReps: 8 },
              { setIndex: 2, targetWeight: 40, targetWeightUnit: "kg", targetReps: 8 },
            ],
          },
        ],
      },
    ],
  };

  const parsed = createOrRefreshWeeklyPlanToolInputSchema.safeParse(payload);
  if (!parsed.success) {
    throw new Error(`Expected create_or_refresh_weekly_plan input to parse: ${parsed.error.message}`);
  }

  const runtimeParsed = parseCreateOrRefreshWeeklyPlanToolInput(payload);
  if (!runtimeParsed.success) {
    throw new Error("Expected runtime parser to accept valid weekly plan payload");
  }

  if (runtimeParsed.data.days[0].exercises[0].sets[0].targetWeight !== 40) {
    throw new Error("Expected first target weight to round-trip");
  }
});
