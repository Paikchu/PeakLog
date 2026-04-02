import { tool } from "./deps.ts";
import {
  commitRunningWorkoutToolInputSchema,
  adjustCurrentOrNextWeekPlanToolInputSchema,
  commitWorkoutToolInputSchema,
  createOrRefreshWeeklyPlanToolInputSchema,
  logPlannedSetCompletionToolInputSchema,
  type AdjustCurrentOrNextWeekPlanToolInput,
  type CommitRunningWorkoutToolInput,
  type CommitWorkoutToolInput,
  type CreateOrRefreshWeeklyPlanToolInput,
  type LogPlannedSetCompletionToolInput,
  type UpdateProfileGoalToolInput,
  updateProfileGoalToolInputSchema,
} from "./schema.ts";

export const COMMIT_WORKOUT_TOOL_NAME = "commit_workout" as const;
export const COMMIT_RUNNING_WORKOUT_TOOL_NAME = "commit_running_workout" as const;
export const UPDATE_PROFILE_GOAL_TOOL_NAME = "update_profile_goal" as const;
export const CREATE_OR_REFRESH_WEEKLY_PLAN_TOOL_NAME = "create_or_refresh_weekly_plan" as const;
export const ADJUST_CURRENT_OR_NEXT_WEEK_PLAN_TOOL_NAME = "adjust_current_or_next_week_plan" as const;
export const LOG_PLANNED_SET_COMPLETION_TOOL_NAME = "log_planned_set_completion" as const;

export interface CommitWorkoutToolOptions {
  onCommitWorkout?: (input: CommitWorkoutToolInput) => Promise<void>;
  onCommitRunningWorkout?: (input: CommitRunningWorkoutToolInput) => Promise<void>;
  onUpdateProfileGoal?: (input: UpdateProfileGoalToolInput) => Promise<void>;
  onCreateOrRefreshWeeklyPlan?: (input: CreateOrRefreshWeeklyPlanToolInput) => Promise<void>;
  onAdjustCurrentOrNextWeekPlan?: (input: AdjustCurrentOrNextWeekPlanToolInput) => Promise<void>;
  onLogPlannedSetCompletion?: (input: LogPlannedSetCompletionToolInput) => Promise<void>;
}

/**
 * AI SDK tools for the workout logging agent (currently only `commit_workout`).
 * Synchronous — no dynamic imports required.
 */
export function createWorkoutAgentTools(options: CommitWorkoutToolOptions) {
  const commit_workout = tool({
    description:
      "Commit a complete workout to the database when the information is sufficient and unambiguous. Executing this tool writes training rows and updates the assistant message immediately.",
    inputSchema: commitWorkoutToolInputSchema,
    // The SDK validates `input` against `inputSchema` (Zod) before calling execute,
    // so no secondary parsing is needed here.
    execute: async (input) => {
      if (options.onCommitWorkout) {
        await options.onCommitWorkout(input);
      }
      return input;
    },
  });

  const commit_running_workout = tool({
    description:
      "Commit a complete running workout to the database when duration and distance are both present and unambiguous.",
    inputSchema: commitRunningWorkoutToolInputSchema,
    execute: async (input) => {
      if (options.onCommitRunningWorkout) {
        await options.onCommitRunningWorkout(input);
      }
      return input;
    },
  });

  const update_profile_goal = tool({
    description:
      "Update the user's long-term training goal summary in their profile when the user sets or changes their goal.",
    inputSchema: updateProfileGoalToolInputSchema,
    execute: async (input) => {
      if (options.onUpdateProfileGoal) {
        await options.onUpdateProfileGoal(input);
      }
      return input;
    },
  });

  const create_or_refresh_weekly_plan = tool({
    description:
      "Create or replace the user's structured weekly training plan when the user asks for a new plan.",
    inputSchema: createOrRefreshWeeklyPlanToolInputSchema,
    execute: async (input) => {
      if (options.onCreateOrRefreshWeeklyPlan) {
        await options.onCreateOrRefreshWeeklyPlan(input);
      }
      return input;
    },
  });

  const adjust_current_or_next_week_plan = tool({
    description:
      "Adjust the current week or next week plan based on user feedback, adherence, or extra training.",
    inputSchema: adjustCurrentOrNextWeekPlanToolInputSchema,
    execute: async (input) => {
      if (options.onAdjustCurrentOrNextWeekPlan) {
        await options.onAdjustCurrentOrNextWeekPlan(input);
      }
      return input;
    },
  });

  const log_planned_set_completion = tool({
    description:
      "Log completion of a single planned set and append it to today's structured workout record.",
    inputSchema: logPlannedSetCompletionToolInputSchema,
    execute: async (input) => {
      if (options.onLogPlannedSetCompletion) {
        await options.onLogPlannedSetCompletion(input);
      }
      return input;
    },
  });

  return {
    [COMMIT_WORKOUT_TOOL_NAME]: commit_workout,
    [COMMIT_RUNNING_WORKOUT_TOOL_NAME]: commit_running_workout,
    [UPDATE_PROFILE_GOAL_TOOL_NAME]: update_profile_goal,
    [CREATE_OR_REFRESH_WEEKLY_PLAN_TOOL_NAME]: create_or_refresh_weekly_plan,
    [ADJUST_CURRENT_OR_NEXT_WEEK_PLAN_TOOL_NAME]: adjust_current_or_next_week_plan,
    [LOG_PLANNED_SET_COMPLETION_TOOL_NAME]: log_planned_set_completion,
  };
}
