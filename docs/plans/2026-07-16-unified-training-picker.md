# Unified Training Picker Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make “添加训练计划” open one unified exercise picker with a cardio category, while removing cardio RPE from every new-input and display path without affecting strength-set RPE or old-data decoding.

**Architecture:** Extend `ExercisePickerScreen` with an opt-in cardio category and callback so its existing strength-only callers remain unchanged. `AddPlanExerciseSheet` becomes picker-first: strength selections route to the existing set form, while a cardio row routes to the existing duration/distance form. Keep optional cardio RPE properties at persistence boundaries for backward compatibility, but ensure every current iOS and generator write path produces `nil` and no UI renders the old values.

**Tech Stack:** Swift 6, SwiftUI, XCTest/standalone Swift regression runners, Node test runner, Supabase Edge Functions/Postgres compatibility DTOs.

---

## Confirmed product rules

- Tapping `today.addPlanExercise` opens the unified picker immediately.
- The deleted screen is the two-card “力量 / 有氧” type picker in `AddPlanExerciseSheet`.
- The unified picker keeps strength search, recommendations, muscle/equipment filters, multi-select, and custom exercise creation.
- A new `有氧` category shows running, cycling, elliptical, and stair climber as selectable rows.
- Strength selection remains multi-select and routes to the existing strength target form.
- Cardio selection is single-select and routes to its duration/distance form.
- Running and cycling accept duration plus optional distance. Elliptical and stair climber accept duration only.
- Cardio RPE is removed from add-plan, manual-record, completion, planned-card, record-card, generator prompt, and generator output paths.
- Strength set RPE remains unchanged.
- Existing `targetRPE`, `rpe`, `target_rpe`, and `running_workouts.rpe` fields remain readable and syncable so old data does not fail decoding.
- No Supabase migration or Edge Function is deployed without separate authorization.

## Implementation constraints

- Work in the isolated `codex/unified-training-picker` feature branch.
- Preserve unrelated dirty files, especially `AGENTS.md`, Xcode user data, `.workbuddy/`, `CLAUDE.md`, existing issue-audit documents, and unrelated localization edits.
- Edit `PeakLog/Localizable.xcstrings` surgically; do not rewrite or reformat the full catalog.
- Do not alter the already-created migration `backend/supabase/migrations/20260715145641_add_cardio_training_plan.sql`; the retained nullable RPE columns are the compatibility boundary.
- Do not commit, push, deploy, or create a PR until the user explicitly authorizes it after validation.

## Test matrix

| Module | Scenario | Verification | Coverage |
|---|---|---|---|
| Today | 单日多个动作的草稿构建与保存 | `tests/daily_record_multi_exercise_draft_test.swift` | 已有 |
| Today | Today 页与运行中训练状态共存不冲突 | `tests/today_running_coexistence_test.swift` | 已有 |
| Today | 训练页浮层布局和添加入口保持可用 | `tests/today_workout_screen_overlay_layout_test.swift` | 已有 |
| Plan | 编辑计划时事件记录正确写入 | `tests/plan_edit_event_recording_test.swift` | 已有 |
| Plan | 计划动作草稿构建正确 | `tests/plan_exercise_draft_builder_test.swift` | 已有 |
| Plan | 专注训练模式无回归 | `tests/plan_focus_training_mode_test.swift` | 已有 |
| Plan | 计划文案本地化正确 | `tests/localized_plan_text_test.swift` | 已有 |
| Auth · Sync | 云端与本地模型双向映射 | `tests/cloud_mapper_roundtrip_test.swift` | 已有 |
| Auth · Sync | 云端拉取与本地状态合并 | `tests/cloud_pull_merge_test.swift` | 已有 |
| Auth · Sync | Schema 演进后旧本地状态仍可解码 | `tests/local_state_decode_compat_test.swift` | 已有 |
| Exercise Library / Picker | 动作库搜索匹配与排序 | `tests/exercise_library_search_test.swift` | 已有 |
| Exercise Library / Picker | 最近使用动作展示 | `tests/exercise_picker_recent_test.swift` | 已有 |
| Exercise Library / Picker | 动作推荐逻辑 | `tests/exercise_recommendation_test.swift` | 已有 |
| Localization（跨模块） | 语言切换与 fallback | `tests/localization_manager_test.swift` | 已有 |
| Exercise Library / Picker | 添加计划直接进入统一选择器；有氧分类包含四种活动 | `tests/cardio_plan_ui_contract_test.swift` + 模拟器手测 | 新增 |
| Plan | 新增有氧计划只保存时长/距离，事件载荷不含 RPE | `tests/plan_edit_event_recording_test.swift` | 新增 |
| Today | 所有有氧输入和卡片无 RPE，力量组级 RPE 保留 | `tests/cardio_plan_ui_contract_test.swift` + 模拟器手测 | 新增 |
| Auth · Sync | 带旧 RPE 的有氧数据仍可解码和 round-trip，新数据写入 nil | `tests/cardio_model_test.swift` + `tests/cloud_mapper_roundtrip_test.swift` | 新增 |
| Plan | 周计划生成与重排不再请求或输出有氧 RPE | `backend/tests/prompt.test.mjs` + `backend/tests/validator.test.mjs` + `backend/tests/contextBuilder.test.mjs` + `backend/tests/cardioGeneratorContract.test.mjs` | 新增 |
| Auth · Sync | 有氧迁移、关联索引和生成函数已部署且线上结构可核验 | Supabase migration/schema/function/Advisor 线上只读核验 | 新增 |

### Task 1: Lock the new UI and compatibility contracts with failing tests

**Files:**
- Modify: `tests/cardio_plan_ui_contract_test.swift:1-34`
- Modify: `tests/cardio_model_test.swift:4-49`
- Modify: `tests/plan_edit_event_recording_test.swift:21-54`
- Modify: `tests/cloud_mapper_roundtrip_test.swift:25-125`
- Modify: `backend/tests/prompt.test.mjs`
- Modify: `backend/tests/validator.test.mjs`
- Modify: `backend/tests/contextBuilder.test.mjs`
- Modify: `backend/tests/cardioGeneratorContract.test.mjs`

**Step 1: Replace the old UI assertions with the unified-picker contract**

Add source assertions equivalent to:

```swift
let picker = try source("PeakLog/Views/Today/ExercisePickerScreen.swift")

precondition(!addPlan.contains("typePicker"))
precondition(!addPlan.contains("planTypeButton"))
precondition(addPlan.contains("onSelectCardio"))
precondition(picker.contains("case cardio"))
precondition(picker.contains("CardioActivityType.allCases"))
precondition(!addPlan.contains("cardioRPE"))
precondition(!dailyRecord.contains("rpeText"))
precondition(!sheet.contains("rpeText"))
precondition(!card.contains("targetRPE"))
precondition(!recordCard.contains("record.rpe"))
precondition(strengthFormSource.contains("set.rpe"))
```

The test should also assert that `ExercisePickerScreen` still exposes strength `onConfirm`, ensuring the existing multi-select path is preserved.

**Step 2: Change the manual cardio event test to require no RPE**

Construct a cardio draft without a `targetRPE` argument and assert:

```swift
precondition(payload["targetRPE"] == nil)
```

Keep assertions for `itemType`, `cardioActivityType`, duration, and optional distance.

**Step 3: Add old-data/new-data model assertions**

- Decode a legacy cardio plan exercise containing `"targetRPE": 6` and assert the value is retained.
- Decode a legacy cardio record containing `"rpe": 7` and assert the value is retained.
- Create new `CardioMetrics` and `PlanExerciseDraft.cardio` values through the new API and assert their compatibility RPE values are `nil`.
- In the cloud round-trip fixture, retain one old row with RPE to prove decoding compatibility, then add a newly created cardio row and assert its encoded RPE is `nil`.

**Step 4: Add backend contract assertions**

- Prompts must not contain `targetRPE` or the phrase `optional targetRPE`.
- Generator normalization must return `targetRPE: null` for cardio until the compatibility property is removed in a future migration.
- Current generated-plan validation must reject or normalize away a non-null `targetRPE`; choose one behavior and test it consistently. Prefer normalization to `null` at the generator boundary so older model responses do not fail a whole plan.
- Replan context must omit old `target_rpe` values so they cannot influence new output.

**Step 5: Run the tests and verify RED**

Run:

```bash
swift tests/cardio_plan_ui_contract_test.swift
node --test backend/tests/prompt.test.mjs backend/tests/validator.test.mjs backend/tests/contextBuilder.test.mjs backend/tests/cardioGeneratorContract.test.mjs
```

Expected: failures identify the existing type picker and RPE references.

### Task 2: Make the exercise picker optionally expose cardio activities

**Files:**
- Modify: `PeakLog/Views/Today/ExercisePickerScreen.swift:8-114`
- Modify: `PeakLog/Views/Today/ExercisePickerScreen.swift:149-250`
- Modify: `PeakLog/Localizable.xcstrings`
- Test: `tests/cardio_plan_ui_contract_test.swift`

**Step 1: Add an opt-in picker category**

Define a small view-local category state rather than converting cardio into a fake `ExerciseDefinition`:

```swift
private enum ExercisePickerCategory: Hashable {
    case strength(MuscleGroup?)
    case cardio
}
```

Add an optional callback:

```swift
var onSelectCardio: ((CardioActivityType) -> Void)? = nil
```

When the callback is `nil`, the picker behaves exactly as before. This preserves the `DailyRecordSheet` strength picker and avoids expanding unrelated flows.

**Step 2: Add the cardio category chip**

- Keep `全部` and existing muscle-group chips.
- Append `有氧` only when `onSelectCardio != nil`.
- Selecting `有氧` clears muscle/equipment filters and switches the content region to cardio rows.
- Switching back to a strength category restores normal strength filtering.

**Step 3: Render four cardio rows**

Use `CardioActivityType.allCases` and existing `localizedTitle`/`iconName` values. Each row calls `onSelectCardio(activity)` directly; cardio is single-select, so the strength multi-select confirmation bar must not appear in cardio mode.

Do not show strength recommendations, equipment chips, custom-exercise creation, or recent strength summaries while the cardio category is active.

**Step 4: Update picker copy**

- Change `exercise_picker.title` from “选择动作 / Choose Exercises” to “选择运动 / Choose Activity”.
- Add a dedicated localized key for the cardio category if `daily_record.type.cardio` is not semantically reusable.
- Keep existing strength copy unchanged.

**Step 5: Run the focused UI contract**

Run:

```bash
swift tests/cardio_plan_ui_contract_test.swift
```

Expected: picker assertions pass; `AddPlanExerciseSheet` assertions remain RED until Task 3.

### Task 3: Remove the type menu and route both kinds of selection from one picker

**Files:**
- Modify: `PeakLog/Views/Today/AddPlanExerciseSheet.swift:3-115`
- Modify: `PeakLog/Views/Today/AddPlanExerciseSheet.swift:117-248`
- Modify: `PeakLog/Models/PlanExerciseFormModel.swift:8-47`
- Test: `tests/cardio_plan_ui_contract_test.swift`
- Test: `tests/plan_edit_event_recording_test.swift`
- Test: `tests/plan_exercise_draft_builder_test.swift`

**Step 1: Make the picker the NavigationStack root**

- Delete `typePicker` and `planTypeButton`.
- Rename `.strengthPicker` to `.picker` or remove that route when the root itself is the picker.
- Root `ExercisePickerScreen` receives both `onConfirm: appendPicked` and `onSelectCardio: selectCardio`.
- Keep the cancellation toolbar available from the picker root.

**Step 2: Preserve the two downstream forms**

- Strength confirmation appends `DailyRecordExerciseInput` and routes to `.strengthForm`.
- Cardio row selection sets `selectedCardioActivity`, clears distance when the type does not support it, and routes to `.cardioForm`.
- The “add another exercise” action in the strength form returns to the same unified picker.
- Returning from either form must preserve the current draft state owned by `AddPlanExerciseSheet`.

**Step 3: Remove cardio RPE from the manual plan draft API**

Change the creation API to:

```swift
static func cardio(
    activityType: CardioActivityType,
    targetDurationMinutes: Int,
    targetDistanceKm: Double?
) throws -> PlanExerciseDraft
```

Internally construct `CardioMetrics(..., rpe: nil)` and set compatibility `targetRPE` to `nil`. Keep the stored `targetRPE` property on `PlanExerciseDraft` only if required by existing mapping code; no new call site may assign a non-nil value.

**Step 4: Remove the cardio RPE input**

- Delete `cardioRPE` state, field rendering, parsing, and validation.
- Keep duration and distance validation.
- Pass only activity, duration, and distance into `PlanExerciseDraft.cardio`.

**Step 5: Run focused plan tests**

Run the commands documented at the top of:

```text
tests/plan_exercise_draft_builder_test.swift
tests/plan_edit_event_recording_test.swift
```

Then run:

```bash
