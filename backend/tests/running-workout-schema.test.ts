import {
  buildAIWorkoutActionResponse,
} from "../supabase/functions/ai-workout-action/helpers.ts";
import {
  commitRunningWorkoutToolInputSchema,
  parseCommitRunningWorkoutToolInput,
} from "../supabase/functions/chat-send-message/schema.ts";

Deno.test("commit running workout schema accepts complete running payload", () => {
  const parsed = commitRunningWorkoutToolInputSchema.safeParse({
    reply: "已为你记录今天的跑步。",
    durationMinutes: 30,
    distanceKm: 5,
  });

  if (!parsed.success) {
    throw new Error(`Expected running payload to pass schema: ${parsed.error.message}`);
  }
});

Deno.test("commit running workout parser rejects payload missing distance", () => {
  const parsed = parseCommitRunningWorkoutToolInput({
    reply: "已记录。",
    durationMinutes: 40,
  });

  if (parsed.success) {
    throw new Error("Expected parser to reject incomplete running payload");
  }
});

Deno.test("ai workout action response marks running records as requiring today refresh", () => {
  const response = buildAIWorkoutActionResponse({
    contentBlocks: [
      { type: "text", text: "已记录夜跑。" },
      {
        type: "running_record",
        running_workout_id: "run-1",
        workout_date: "2026-04-01",
        duration_minutes: 28,
        distance_km: 4.8,
      },
    ],
  });

  if (!response.requiresTodayRefresh) {
    throw new Error("Expected running_record content to request a today refresh");
  }
});
