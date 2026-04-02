import { z } from "./deps.ts";

export interface ParsedExerciseSet {
  setIndex: number;
  weight: number | null;
  weightUnit: string;
  reps: number;
}

export interface ParsedExercise {
  name: string;
  exerciseType?: "bodyweight" | "weighted" | "unknown";
  weightSource?: "explicit" | "inferred_bodyweight" | "omitted";
  sets: ParsedExerciseSet[];
}

export interface RecentSavedRecordSummary {
  workoutSessionId: string;
  workoutDate: string;
  summaryText: string;
  sourceMessageId?: string;
}

export interface CommitWorkoutToolInput {
  reply: string;
  workoutDate?: string;
  exercises: ParsedExercise[];
}

export interface CommitRunningWorkoutToolInput {
  reply: string;
  workoutDate?: string;
  durationMinutes: number;
  distanceKm: number;
}

export interface TrainingPlanSetInput {
  planSetId?: string;
  setIndex: number;
  targetWeight: number | null;
  targetWeightUnit: string;
  targetReps: number;
}

export interface TrainingPlanExerciseInput {
  planExerciseId?: string;
  orderIndex: number;
  exerciseName: string;
  exerciseLoadType: "bodyweight" | "weighted" | "unknown";
  progressionMode: "weight_first" | "reps_first" | "maintain";
  notes?: string | null;
  sets: TrainingPlanSetInput[];
}

export interface TrainingPlanDayInput {
  planDayId?: string;
  planDate: string;
  dayIndex: number;
  title: string;
  focus?: string | null;
  status: "planned" | "in_progress" | "completed" | "skipped" | "rest";
  exercises: TrainingPlanExerciseInput[];
}

export interface UpdateProfileGoalToolInput {
  goalSummary: string;
  reply: string;
}

export interface CreateOrRefreshWeeklyPlanToolInput {
  reply: string;
  weekStartDate: string;
  coachSummary: string;
  days: TrainingPlanDayInput[];
}

export interface AdjustCurrentOrNextWeekPlanToolInput {
  reply: string;
  targetWeek: string;
  adjustmentReason: string;
  coachSummary: string;
  days: TrainingPlanDayInput[];
}

export interface LogPlannedSetCompletionToolInput {
  reply: string;
  planSetId: string;
  actualWeight: number | null;
  actualWeightUnit: string;
  actualReps: number;
}

const parsedExerciseSetSchema = z.object({
  setIndex: z.number(),
  weight: z.number().nullable(),
  weightUnit: z.string(),
  reps: z.number(),
});

const parsedExerciseSchema = z.object({
  name: z.string(),
  exerciseType: z.enum(["bodyweight", "weighted", "unknown"]).optional(),
  weightSource: z.enum(["explicit", "inferred_bodyweight", "omitted"]).optional(),
  sets: z.array(parsedExerciseSetSchema),
});

const trainingPlanSetSchema = z.object({
  planSetId: z.string().optional(),
  setIndex: z.number(),
  targetWeight: z.number().nullable(),
  targetWeightUnit: z.string(),
  targetReps: z.number(),
});

const trainingPlanExerciseSchema = z.object({
  planExerciseId: z.string().optional(),
  orderIndex: z.number(),
  exerciseName: z.string(),
  exerciseLoadType: z.enum(["bodyweight", "weighted", "unknown"]),
  progressionMode: z.enum(["weight_first", "reps_first", "maintain"]),
  notes: z.string().nullable().optional(),
  sets: z.array(trainingPlanSetSchema),
});

const trainingPlanDaySchema = z.object({
  planDayId: z.string().optional(),
  planDate: z.string(),
  dayIndex: z.number(),
  title: z.string(),
  focus: z.string().nullable().optional(),
  status: z.enum(["planned", "in_progress", "completed", "skipped", "rest"]),
  exercises: z.array(trainingPlanExerciseSchema),
});

/** Zod schema is the single source of truth for `commit_workout` tool input validation. */
export const commitWorkoutToolInputSchema = z.object({
  reply: z.string(),
  workoutDate: z.string().optional(),
  exercises: z.array(parsedExerciseSchema).min(1),
});

export const commitRunningWorkoutToolInputSchema = z.object({
  reply: z.string().min(1),
  workoutDate: z.string().optional(),
  durationMinutes: z.number().int().positive(),
  distanceKm: z.number().positive(),
});

export const updateProfileGoalToolInputSchema = z.object({
  goalSummary: z.string().min(1),
  reply: z.string().min(1),
});

export const createOrRefreshWeeklyPlanToolInputSchema = z.object({
  reply: z.string().min(1),
  weekStartDate: z.string(),
  coachSummary: z.string().min(1),
  days: z.array(trainingPlanDaySchema).length(7).or(z.array(trainingPlanDaySchema).min(1)),
});

export const adjustCurrentOrNextWeekPlanToolInputSchema = z.object({
  reply: z.string().min(1),
  targetWeek: z.string(),
  adjustmentReason: z.string().min(1),
  coachSummary: z.string().min(1),
  days: z.array(trainingPlanDaySchema).length(7).or(z.array(trainingPlanDaySchema).min(1)),
});

export const logPlannedSetCompletionToolInputSchema = z.object({
  reply: z.string().min(1),
  planSetId: z.string().min(1),
  actualWeight: z.number().nullable(),
  actualWeightUnit: z.string().min(1),
  actualReps: z.number().int().nonnegative(),
});

/**
 * Lightweight runtime guard used by `stream-events.ts` and `extractCommitWorkout` for unknown
 * payloads (e.g. partial JSON from SSE, onFinish toolCalls). Intentionally separate from Zod so
 * that neither path depends on async schema loading.
 */
export function parseCommitWorkoutToolInput(value: unknown): {
  success: true;
  data: CommitWorkoutToolInput;
} | {
  success: false;
} {
  if (typeof value !== "object" || value === null) {
    return { success: false };
  }

  const record = value as Record<string, unknown>;
  if (typeof record.reply !== "string" || !Array.isArray(record.exercises) || record.exercises.length === 0) {
    return { success: false };
  }

  const exercises: ParsedExercise[] = [];
  for (const exerciseValue of record.exercises) {
    if (typeof exerciseValue !== "object" || exerciseValue === null) {
      return { success: false };
    }

    const exercise = exerciseValue as Record<string, unknown>;
    if (typeof exercise.name !== "string" || !Array.isArray(exercise.sets)) {
      return { success: false };
    }

    const sets: ParsedExerciseSet[] = [];
    for (const setValue of exercise.sets) {
      if (typeof setValue !== "object" || setValue === null) {
        return { success: false };
      }

      const set = setValue as Record<string, unknown>;
      if (
        typeof set.setIndex !== "number" ||
        (set.weight !== null && typeof set.weight !== "number") ||
        typeof set.weightUnit !== "string" ||
        typeof set.reps !== "number"
      ) {
        return { success: false };
      }

      sets.push({
        setIndex: set.setIndex,
        weight: set.weight as number | null,
        weightUnit: set.weightUnit,
        reps: set.reps,
      });
    }

    exercises.push({
      name: exercise.name,
      exerciseType: exercise.exerciseType as ParsedExercise["exerciseType"] | undefined,
      weightSource: exercise.weightSource as ParsedExercise["weightSource"] | undefined,
      sets,
    });
  }

  return {
    success: true,
    data: {
      reply: record.reply,
      workoutDate: typeof record.workoutDate === "string" ? record.workoutDate : undefined,
      exercises,
    },
  };
}

export function parseCommitRunningWorkoutToolInput(value: unknown): {
  success: true;
  data: CommitRunningWorkoutToolInput;
} | {
  success: false;
} {
  if (typeof value !== "object" || value === null) {
    return { success: false };
  }

  const record = value as Record<string, unknown>;
  if (
    typeof record.reply !== "string" ||
    typeof record.durationMinutes !== "number" ||
    typeof record.distanceKm !== "number"
  ) {
    return { success: false };
  }

  return {
    success: true,
    data: {
      reply: record.reply,
      workoutDate: typeof record.workoutDate === "string" ? record.workoutDate : undefined,
      durationMinutes: record.durationMinutes,
      distanceKm: record.distanceKm,
    },
  };
}

function parseTrainingPlanSet(value: unknown): TrainingPlanSetInput | null {
  if (typeof value !== "object" || value === null) return null;
  const record = value as Record<string, unknown>;
  if (
    typeof record.setIndex !== "number" ||
    (record.targetWeight !== null && typeof record.targetWeight !== "number") ||
    typeof record.targetWeightUnit !== "string" ||
    typeof record.targetReps !== "number"
  ) {
    return null;
  }

  return {
    planSetId: typeof record.planSetId === "string" ? record.planSetId : undefined,
    setIndex: record.setIndex,
    targetWeight: record.targetWeight as number | null,
    targetWeightUnit: record.targetWeightUnit,
    targetReps: record.targetReps,
  };
}

function parseTrainingPlanExercise(value: unknown): TrainingPlanExerciseInput | null {
  if (typeof value !== "object" || value === null) return null;
  const record = value as Record<string, unknown>;
  if (
    typeof record.orderIndex !== "number" ||
    typeof record.exerciseName !== "string" ||
    !["bodyweight", "weighted", "unknown"].includes(String(record.exerciseLoadType)) ||
    !["weight_first", "reps_first", "maintain"].includes(String(record.progressionMode)) ||
    !Array.isArray(record.sets)
  ) {
    return null;
  }

  const sets = record.sets.map(parseTrainingPlanSet);
  if (sets.some((set) => set === null)) {
    return null;
  }

  return {
    planExerciseId: typeof record.planExerciseId === "string" ? record.planExerciseId : undefined,
    orderIndex: record.orderIndex,
    exerciseName: record.exerciseName,
    exerciseLoadType: record.exerciseLoadType as TrainingPlanExerciseInput["exerciseLoadType"],
    progressionMode: record.progressionMode as TrainingPlanExerciseInput["progressionMode"],
    notes: typeof record.notes === "string" ? record.notes : record.notes === null ? null : undefined,
    sets: sets as TrainingPlanSetInput[],
  };
}

function parseTrainingPlanDay(value: unknown): TrainingPlanDayInput | null {
  if (typeof value !== "object" || value === null) return null;
  const record = value as Record<string, unknown>;
  if (
    typeof record.planDate !== "string" ||
    typeof record.dayIndex !== "number" ||
    typeof record.title !== "string" ||
    !["planned", "in_progress", "completed", "skipped", "rest"].includes(String(record.status)) ||
    !Array.isArray(record.exercises)
  ) {
    return null;
  }

  const exercises = record.exercises.map(parseTrainingPlanExercise);
  if (exercises.some((exercise) => exercise === null)) {
    return null;
  }

  return {
    planDayId: typeof record.planDayId === "string" ? record.planDayId : undefined,
    planDate: record.planDate,
    dayIndex: record.dayIndex,
    title: record.title,
    focus: typeof record.focus === "string" ? record.focus : record.focus === null ? null : undefined,
    status: record.status as TrainingPlanDayInput["status"],
    exercises: exercises as TrainingPlanExerciseInput[],
  };
}

export function parseCreateOrRefreshWeeklyPlanToolInput(value: unknown): {
  success: true;
  data: CreateOrRefreshWeeklyPlanToolInput;
} | { success: false } {
  if (typeof value !== "object" || value === null) return { success: false };
  const record = value as Record<string, unknown>;
  if (
    typeof record.reply !== "string" ||
    typeof record.weekStartDate !== "string" ||
    typeof record.coachSummary !== "string" ||
    !Array.isArray(record.days)
  ) {
    return { success: false };
  }

  const days = record.days.map(parseTrainingPlanDay);
  if (days.length === 0 || days.some((day) => day === null)) {
    return { success: false };
  }

  return {
    success: true,
    data: {
      reply: record.reply,
      weekStartDate: record.weekStartDate,
      coachSummary: record.coachSummary,
      days: days as TrainingPlanDayInput[],
    },
  };
}

export function parseAdjustCurrentOrNextWeekPlanToolInput(value: unknown): {
  success: true;
  data: AdjustCurrentOrNextWeekPlanToolInput;
} | { success: false } {
  if (typeof value !== "object" || value === null) return { success: false };
  const record = value as Record<string, unknown>;
  if (
    typeof record.reply !== "string" ||
    typeof record.targetWeek !== "string" ||
    typeof record.adjustmentReason !== "string" ||
    typeof record.coachSummary !== "string" ||
    !Array.isArray(record.days)
  ) {
    return { success: false };
  }

  const days = record.days.map(parseTrainingPlanDay);
  if (days.length === 0 || days.some((day) => day === null)) {
    return { success: false };
  }

  return {
    success: true,
    data: {
      reply: record.reply,
      targetWeek: record.targetWeek,
      adjustmentReason: record.adjustmentReason,
      coachSummary: record.coachSummary,
      days: days as TrainingPlanDayInput[],
    },
  };
}

export function parseLogPlannedSetCompletionToolInput(value: unknown): {
  success: true;
  data: LogPlannedSetCompletionToolInput;
} | { success: false } {
  if (typeof value !== "object" || value === null) return { success: false };
  const record = value as Record<string, unknown>;
  if (
    typeof record.reply !== "string" ||
    typeof record.planSetId !== "string" ||
    (record.actualWeight !== null && typeof record.actualWeight !== "number") ||
    typeof record.actualWeightUnit !== "string" ||
    typeof record.actualReps !== "number"
  ) {
    return { success: false };
  }

  return {
    success: true,
    data: {
      reply: record.reply,
      planSetId: record.planSetId,
      actualWeight: record.actualWeight as number | null,
      actualWeightUnit: record.actualWeightUnit,
      actualReps: record.actualReps,
    },
  };
}

/** If the tool sends a valid YYYY-MM-DD, use it; otherwise use server `today` (Edge request day). */
export function pickWorkoutSessionDate(
  workoutDateFromTool: string | undefined,
  today: string,
): string {
  if (workoutDateFromTool && /^\d{4}-\d{2}-\d{2}$/.test(workoutDateFromTool)) {
    return workoutDateFromTool;
  }
  return today;
}
