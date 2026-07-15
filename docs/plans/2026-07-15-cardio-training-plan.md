# Cardio Training Plan Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add running, cycling, elliptical, and stair-climber activities to generated weekly plans with type-specific targets, completion UI, history, and backward-compatible cloud sync.

**Architecture:** Keep `TrainingPlanExercise` as the ordered plan-item container and add a discriminant plus optional cardio targets; strength items retain their existing set payload. Rename the iOS running domain to generic cardio while keeping the physical `running_workouts` table and local JSON key for old-client compatibility. Complete a planned cardio item through one `LocalAppDatabase` transaction that creates the record and links the plan item.

**Tech Stack:** Swift 6, SwiftUI, XCTest, local JSON persistence, Supabase Postgres/PostgREST, Deno Edge Functions, Node test runner.

---

## Technical decisions

- `PlanItemType`: `strength | cardio`; missing values decode as `strength`.
- `CardioActivityType`: `running | cycling | elliptical | stairClimber`.
- Every cardio plan item requires `targetDurationMinutes > 0`.
- Running and cycling may include `targetDistanceKm > 0`; elliptical and stair climber reject distance.
- `targetRPE` and actual `rpe` are optional decimals in `1...10`.
- Existing `running_workouts` remains the PostgREST table. New columns make it a compatibility-backed generic cardio store; a table rename would break installed clients.
- Existing local JSON continues encoding under `runningRecords`; the value type becomes `CardioWorkoutRecord`, and missing `activityType` decodes as `.running`.
- Default weekly generation may add one or two low/moderate cardio items when the session-time budget permits. It may place cardio after strength on the same day; it must not increase `goalSpec.daysPerWeek` or replace required recovery with hard cardio.
- The existing strength focus session remains strength-only. Cardio starts from its own plan card and uses an item-driven completion sheet.
- No remote migration or Edge Function deployment in this implementation.

### Task 1: Add backward-compatible cardio domain models

**Files:**
- Modify: `PeakLog/Models/TrainingPlanModels.swift`
- Modify: `PeakLog/Models/WorkoutModels.swift`
- Modify: `PeakLog/Services/LocalAppDatabase.swift`
- Test: `PeakLogTests/CardioModelCompatibilityTests.swift`
- Test: `tests/local_state_decode_compat_test.swift`

**Step 1: Write failing compatibility tests**

- Decode a legacy `TrainingPlanExercise` without `itemType` and assert `.strength`.
- Decode a legacy `RunningWorkoutRecord` without `activityType`, `rpe`, or nullable distance and assert `.running`.
- Encode/decode cycling with duration, distance, and RPE.
- Reject invalid model construction through a central `CardioMetrics` validator: non-positive duration, non-positive distance, elliptical distance, and RPE outside `1...10`.

**Step 2: Run the tests and verify RED**

```bash
xcodebuild test -project PeakLog.xcodeproj -scheme PeakLog \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -parallel-testing-enabled NO -disable-concurrent-destination-testing \
  -only-testing:PeakLogTests/CardioModelCompatibilityTests
```

Expected: compile failure because the cardio types and compatibility decoder do not exist.

**Step 3: Implement the models**

- Add `PlanItemType`, `CardioActivityType`, and `CardioMetrics`.
- Extend `TrainingPlanExercise` with `itemType`, `cardioActivityType`, `targetDurationMinutes`, `targetDistanceKm`, `targetRPE`, `cardioCompletedAt`, and `linkedCardioWorkoutId`.
- Add explicit `Codable` handling so old plan JSON supplies strength defaults.
- Replace `RunningWorkoutRecord` with `CardioWorkoutRecord`; keep a temporary typealias only if required to avoid a single oversized migration commit.
- Make actual `distanceKm` optional and add `activityType`, `rpe`, and `source`.
- Preserve the `LocalAppState.CodingKeys.runningRecords` persisted key.
- Add plan progress helpers that count each completed cardio item as one unit and every strength set as one unit.

**Step 4: Run focused tests and verify GREEN**

Run the command from Step 2 plus:

```bash
swiftc -parse-as-library \
  PeakLog/Models/TrainingPlanModels.swift \
  PeakLog/Models/WorkoutModels.swift \
  tests/local_state_decode_compat_test.swift \
  -o /tmp/peaklog-local-state-compat && /tmp/peaklog-local-state-compat
```

Expected: model XCTest passes; compatibility runner prints its pass marker.

### Task 2: Add an additive Supabase migration

**Files:**
- Create via CLI: `backend/supabase/migrations/<generated>_add_cardio_training_plan.sql`
- Test: `backend/tests/cardioTrainingPlanMigration.test.mjs`

**Step 1: Discover the installed CLI surface**

```bash
supabase --version
supabase migration new --help
supabase db reset --help
```

Expected: commands and flags are printed; do not infer flags from memory.

**Step 2: Generate the migration file**

```bash
cd backend && supabase migration new add_cardio_training_plan
```

Expected: the CLI creates the timestamped SQL file under `backend/supabase/migrations/`.

**Step 3: Write a failing migration contract test**

Assert that the generated migration:

- Adds the seven plan-item columns and five cardio-record columns.
- Defaults existing plan rows to `item_type = 'strength'`.
- Defaults existing running rows to `activity_type = 'running'`.
- Drops `running_workouts.distance_km` NOT NULL while preserving a positive-if-present check.
- Adds activity type, duration, distance, and RPE checks.
- Adds a composite ownership-safe link from `(linked_cardio_workout_id, user_id)` to `running_workouts(id, user_id)`.
- Does not disable or broaden RLS and does not add a `SECURITY DEFINER` function.

Run:

```bash
node --test backend/tests/cardioTrainingPlanMigration.test.mjs
```

Expected: FAIL until the SQL is populated.

**Step 4: Implement the migration**

- Add to `training_plan_exercises`: `item_type`, `cardio_activity_type`, `target_duration_minutes`, `target_distance_km`, `target_rpe`, `cardio_completed_at`, `linked_cardio_workout_id`.
- Add to `running_workouts`: `activity_type`, nullable `distance_km`, `rpe`, and retain existing `duration_minutes`, source, timestamps, and ownership.
- Add `UNIQUE (id, user_id)` to `running_workouts`, then the composite FK from the plan item. Use the default restrictive delete behavior; a linked record cannot be deleted until the plan link is cleared.
- Add checks that distinguish strength and cardio payloads. Strength rows cannot carry cardio targets; cardio rows require a supported type and positive duration.
- Preserve the existing RLS policy. This migration adds no table, role grant, view, or privileged function.

**Step 5: Verify locally**

```bash
node --test backend/tests/cardioTrainingPlanMigration.test.mjs
cd backend && supabase db reset
```

Expected: contract test passes; local database reset applies every migration. If Docker/local Supabase is unavailable, record that limitation and do not deploy remotely as a substitute.

### Task 3: Generalize local persistence, services, and cloud mapping

**Files:**
- Modify: `PeakLog/Services/WorkoutService.swift`
- Modify: `PeakLog/Services/TrainingPlanService.swift`
- Modify: `PeakLog/Services/LocalAppDatabase.swift`
- Modify: `PeakLog/Services/Cloud/CloudRows.swift`
- Modify: `PeakLog/Services/Cloud/CloudMapper.swift`
- Modify: `PeakLog/Services/Cloud/LocalDataSnapshot.swift`
- Modify: `PeakLog/Services/Cloud/CloudSnapshotLoader.swift`
- Modify: `PeakLog/Services/Cloud/CloudSyncCoordinator.swift`
- Modify: affected fake services under `PeakLogTests/` and `tests/`
- Test: `PeakLogTests/CardioPlanCompletionTests.swift`
- Test: `PeakLogTests/CloudMapperTests.swift`

**Step 1: Write failing service tests**

- Completing a planned running item creates one record and links that item.
- Repeating completion returns the existing record or a duplicate-completion error; it never creates a second record.
- A forced persistence failure rolls back both record creation and plan completion.
- Manual cycling/elliptical/stair-climber records round-trip through local storage.
- Cloud mapping defaults legacy rows to running and preserves nullable distance/RPE/type on new rows.

**Step 2: Run focused XCTest and verify RED**

```bash
xcodebuild test -project PeakLog.xcodeproj -scheme PeakLog \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -parallel-testing-enabled NO -disable-concurrent-destination-testing \
  -only-testing:PeakLogTests/CardioPlanCompletionTests \
  -only-testing:PeakLogTests/CloudMapperTests
```

Expected: compile/test failures for the missing generic APIs.

**Step 3: Implement one atomic completion API**

- Replace `runningRecordsForDay`/`createRunningRecord` with generic cardio equivalents across the protocol and local service.
- Add `completePlannedCardio(planExerciseId:actualMetrics:)` to `TrainingPlanServiceProtocol` and `LocalAppDatabase`.
- Validate that the item is cardio, not already linked, and actual metrics match the activity type.
- Mutate the cardio record and plan link in memory, call `persist()` once, and restore the pre-mutation snapshot on failure.
- Clear a plan link before any future linked cardio-record deletion.
- Keep cloud push order as cardio records before plan exercises so the FK target exists.

**Step 4: Extend cloud DTOs and mapping**

- Add all new columns to `TrainingPlanExerciseRow` and `RunningWorkoutRow`.
- Map absent legacy fields to strength/running defaults.
- Keep the table route as `running_workouts` and the persisted collection key as `runningRecords`.
- Update ownership validation to reject a linked cardio record belonging to another user.

**Step 5: Run focused tests and verify GREEN**

Run the command from Step 2 and the existing rollback/cloud round-trip tests.

Expected: all targeted XCTest cases pass without changing strength behavior.

### Task 4: Extend weekly generation and midweek replan contracts

**Files:**
- Modify: `backend/supabase/functions/_shared/prompt.mjs`
- Modify: `backend/supabase/functions/_shared/validator.mjs`
- Modify: `backend/supabase/functions/_shared/contextBuilder.mjs`
- Modify: `backend/supabase/functions/generate-weekly-plan/index.ts`
- Modify: generated cardio migration RPC definitions, or create a second migration via `supabase migration new update_plan_generation_for_cardio` if replacing deployed RPCs cannot live safely in the schema migration
- Modify: `backend/tests/validator.test.mjs`
- Modify: `backend/tests/contextBuilder.test.mjs`
- Test: `backend/tests/cardioPlanGeneration.test.mjs`

**Step 1: Write failing validator tests**

- Accept running/cycling with duration and optional distance.
- Accept elliptical/stair climber with duration and optional RPE.
- Reject unknown types, zero/negative duration, invalid distance, elliptical/stair distance, out-of-range RPE, sets on cardio, and cardio fields on strength.
- Verify weekly and replan validators share the same item checks.
- Verify training-day counting treats a mixed or cardio-only non-empty day as one training day.

Run:

```bash
node --test backend/tests/validator.test.mjs backend/tests/contextBuilder.test.mjs backend/tests/cardioPlanGeneration.test.mjs
```

Expected: new tests fail before validator/prompt changes.

**Step 2: Change the LLM output contract**

- Bump `PROMPT_VERSION` and `REPLAN_PROMPT_VERSION`.
- Add `itemType` and the cardio target fields to both output schemas.
- State the one-to-two easy/moderate cardio default and recovery/session-duration guardrails.
- Require strength fields only for strength and cardio fields only for cardio.
- Include current cardio completion and history in replan context so completed cardio is never rewritten.

**Step 3: Branch validation by item type**

- Keep existing library/load/reps/weight clamping for strength.
- Add deterministic cardio structural validation without hard-coded coaching decisions.
- Normalize missing `itemType` to strength only for old fallback/current-plan context, not for malformed new LLM output.

**Step 4: Update install and replan RPC payloads**

- Insert every new plan-item column.
- Insert no `training_plan_sets` for cardio items.
- Preserve completed cardio rows during replan eligibility checks in the same way completed strength sets protect a day.
- Keep both RPCs service-role-only and retain explicit revokes.

**Step 5: Run backend tests and verify GREEN**

```bash
node --test backend/tests/*.test.mjs
```

Expected: full backend suite passes.

### Task 5: Add type-specific Today cards and completion sheet

**Files:**
- Modify: `PeakLog/Views/Today/TodayWorkoutScreen.swift`
- Create: `PeakLog/Views/Today/PlannedCardioCard.swift`
- Create: `PeakLog/Views/Today/CardioCompletionSheet.swift`
- Modify: `PeakLog/ViewModels/TodayWorkoutViewModel.swift`
- Modify: `PeakLog/Localization/Localizable.xcstrings`
- Test: `PeakLogTests/TodayCardioPlanFlowTests.swift`
- Test: `tests/cardio_plan_ui_contract_test.swift`

**Step 1: Write failing view-model and source-contract tests**

- Strength items still render `TodayPlannedExerciseCard`.
- Cardio items render `PlannedCardioCard` and never render set controls.
- Running/cycling expose duration, optional distance, and RPE.
- Elliptical/stair climber expose duration and RPE but no distance input.
- Saving failure leaves the item incomplete and the sheet input intact.
- Repeated save taps are disabled while saving.

**Step 2: Run tests and verify RED**

Use focused XCTest plus the repo’s existing `swiftc -parse-as-library` source-contract pattern.

Expected: missing component/state failures.

**Step 3: Implement presentation state**

- Add one local `CardioSheetDestination: Identifiable` carrying the selected plan item.
- Present with `.sheet(item:)`; do not add parallel booleans or `if let` inside sheet content.
- The sheet owns validation, saving state, error display, and dismissal. It dismisses only after the completion API succeeds.

**Step 4: Implement the cards**

- Use a stable activity icon and localized label per type.
- Display target chips for duration, optional distance, and optional RPE.
- Completed items show actual values and a completed state.
- Preserve existing swipe deletion, long-press reorder, Dynamic Type, Reduce Motion, and app theme tokens.
- Exclude cardio items from `PlanLiveWorkoutSession`; the main “开始训练” button remains available only when strength sets exist.

**Step 5: Implement view-model completion state**

- Add an async completion method with one in-flight item ID.
- On success, refresh today plan and cardio records.
- On failure, expose the error to the sheet without optimistic completion.

**Step 6: Run focused tests and build**

```bash
xcodebuild test -project PeakLog.xcodeproj -scheme PeakLog \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -parallel-testing-enabled NO -disable-concurrent-destination-testing \
  -only-testing:PeakLogTests/TodayCardioPlanFlowTests

xcodebuild build -project PeakLog.xcodeproj -scheme PeakLog \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5'
```

Expected: focused flow passes and the app builds with zero compiler errors.

### Task 6: Add manual cardio plan entry and generalize record/history UI

**Files:**
- Modify: `PeakLog/Views/Today/AddPlanExerciseSheet.swift`
- Modify: `PeakLog/Models/PlanExerciseFormModel.swift`
- Modify: `PeakLog/Services/LocalAppDatabase.swift`
- Modify: `PeakLog/Views/Today/DailyRecordSheet.swift`
- Modify: `PeakLog/Views/Today/RunningRecordCard.swift` and rename to `CardioRecordCard.swift` if Xcode filesystem synchronization preserves the target automatically
- Modify: `PeakLog/Views/History/HistoryScreen.swift`
- Modify: `PeakLog/ViewModels/HistoryViewModel.swift`
- Modify: `PeakLog/Localization/Localizable.xcstrings`
- Test: `PeakLogTests/CardioHistoryTests.swift`
- Modify: `tests/history_session_aggregation_test.swift`

**Step 1: Write failing history/form tests**

- The add-plan sheet starts with an explicit strength/cardio choice.
- Manual cardio plan drafts preserve type, duration, optional distance, and RPE without strength sets.
- The `exercise_added` edit event carries the same cardio targets for later generation context.
- Manual form selects all four types and applies per-type field requirements.
- History shows localized type, duration, optional distance, and optional RPE.
- Calendar active-day aggregation includes every cardio type.
- Legacy running records keep their current visible values.

**Step 2: Implement the generic form and cards**

- Route strength selection to the existing exercise picker and cardio selection to a dedicated target form.
- Persist manual cardio entries through the existing `addPlannedExercises` transaction and append a complete edit-event snapshot.
- Replace the single cardio form mode with an activity-type picker.
- Hide distance for elliptical/stair climber and make it optional for running/cycling.
- Generalize record-card text and icon without changing the strength history layout.
- Rename internal `runningRecords` state to `cardioRecords` where it improves domain clarity; retain compatibility only at storage/cloud boundaries.

**Step 3: Run focused and regression tests**

Run `CardioHistoryTests`, `HistoryScreenParallelLoadTests`, history aggregation runners, and the existing selected-date/calendar tests.

Expected: all history and calendar regressions pass.

### Task 7: Full verification and delivery documentation

**Files:**
- Create: `docs/logs/2026-07-15-cardio-training-plan.md`
- Modify: `docs/architecture/` contract documents that describe plan or workout payloads

**Step 1: Run static and backend verification**

```bash
git diff --check
node --test backend/tests/*.test.mjs
```

Expected: no whitespace failures; full backend suite passes.

**Step 2: Run full iOS tests serially**

```bash
open -a Simulator
xcodebuild test -project PeakLog.xcodeproj -scheme PeakLog \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -parallel-testing-enabled NO -disable-concurrent-destination-testing
```

Expected: `** TEST SUCCEEDED **`. If the first test stalls with no log progress, follow the repository’s Simulator host-contention procedure before diagnosing product code.

**Step 3: Simulator acceptance**

- Mixed strength + running day.
- Running by time only; cycling by time + distance.
- Elliptical and stair climber without distance.
- Save failure and retry; rapid duplicate submit.
- Offline completion, relaunch, and later cloud-sync preparation.
- Legacy running history after app upgrade.
- Chinese and English, large Dynamic Type, Reduce Motion.

**Step 4: Document actual evidence and residual risk**

- Record commands, pass/fail results, simulator evidence, migration status, and untested paths.
- State explicitly that migration and Edge Function changes are local only.
- Do not commit, push, create a PR, or deploy Supabase until separately authorized.
