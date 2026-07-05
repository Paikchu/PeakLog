# 日记录与添加训练计划支持一次添加多个动作、每组独立重量次数

## 需求

「添加记录」表单（今日页右下角 + → 日记录）原先一次只能录入一个动作，且所有组共用同一个重量和次数。本次改造为：

1. 一次可添加多个训练动作；
2. 每个动作内的每一组可以填写不同的重量和次数；
3. 「自重/负重」从表单全局下沉到每个动作（同一次训练可混合卧推与引体向上）；
4. UI 与主题风格对齐（玻璃卡片、workoutPanel 色板、ValueEditSheet 数值编辑）。

## 改动

- 新增 `PeakLog/Models/DailyRecordFormModel.swift`：
  - `DailyRecordSetInput` / `DailyRecordExerciseInput` 表单可编辑状态（含 `appendSetCopyingLast`：新增一组时沿用上一组数值；`removeLastSet` 保底保留一组）；
  - `DailyRecordDraftBuilder.strengthDraft(...)` 纯函数，把表单状态映射为 `StrengthSessionDraft`，任一动作不完整（名称为空、次数为 0、负重动作缺重量）时返回 nil，用于禁用保存按钮。自重动作强制 weight 为 nil。
- 重写 `PeakLog/Views/Today/DailyRecordSheet.swift`：
  - 顶部「力量 / 有氧」胶囊分段控件（accentGradient 选中态）；
  - 力量模式：标题输入 + 动作卡片列表（glassPanel + accentPrimary 描边，风格对齐 `TodayPlannedExerciseCard`）+ 虚线「添加动作」按钮；
  - 动作卡片：名称输入、负重/自重切换胶囊、减一组、删除动作（多于一个动作时显示）；每组一行：序号圆 + 重量 chip × 次数 chip，点击弹出 `ValueEditSheet`（复用 `ExerciseCardView.swift` 中的组件与 `formatWeightValue`）；
  - 有氧模式：时长/距离输入改为主题化样式；
  - 保存路径不变：`DailyRecordDraft` → `TodayWorkoutViewModel.addDailyRecord` → `WorkoutService.createStrengthSession`。数据链路本就支持多动作、逐组数值，本次无服务层/存储层改动。
- `PeakLog/Localizable.xcstrings` 新增 key（en / zh-Hans）：`daily_record.add_exercise`、`daily_record.add_set`、`daily_record.delete_exercise`、`daily_record.load.weighted`、`daily_record.load.bodyweight`。
- 新增回归测试 `tests/daily_record_multi_exercise_draft_test.swift`：多动作逐组映射、自重强制 nil 重量、不完整表单返回 nil、复制上一组、标题裁剪。

## 第二阶段：添加训练计划表单同步升级

- 新增 `PeakLog/Models/PlanExerciseFormModel.swift`：`PlanExerciseDraft`（多动作、逐组 target）与 `PlanExerciseDraftBuilder`，表单状态复用 `DailyRecordExerciseInput`，校验规则与日记录一致。
- 新增 `PeakLog/Views/Today/ExerciseFormComponents.swift`：把日记录表单里的动作卡片/组行/虚线按钮抽为共享组件 `ExerciseFormCard` / `ExerciseFormSetRow` / `AddExerciseDashedButton`，`DailyRecordSheet` 与 `AddPlanExerciseSheet` 共用。
- 重写 `AddPlanExerciseSheet`：多动作卡片 + 逐组目标（重量 × 次数 chip + ValueEditSheet 编辑），移除旧的 `AddPlanExerciseDraft`（统一目标 + 组数）表单。
- API 改为批量：`TrainingPlanServiceProtocol.addPlannedExercise(单个, 统一目标)` → `addPlannedExercises(_: [PlanExerciseDraft])`；`LocalAppDatabase` 一次事务追加多个动作（保留"找到/创建今日 day"与 manual day 标题逻辑）；`TodayWorkoutViewModel.addPlanExercise` → `addPlanExercises`。
- 同步更新协议 stub：`PeakLogTests/TodayWorkoutLiveSessionTests.swift`、`tests/today_running_coexistence_test.swift`。
- 新增回归测试 `tests/plan_exercise_draft_builder_test.swift`。

## 验证

- `swiftc -parse-as-library PeakLog/Models/WorkoutModels.swift PeakLog/Models/DailyRecordFormModel.swift tests/daily_record_multi_exercise_draft_test.swift -o /tmp/daily_record_test && /tmp/daily_record_test` 通过。
- `swiftc -parse-as-library PeakLog/Models/WorkoutModels.swift PeakLog/Models/DailyRecordFormModel.swift PeakLog/Models/PlanExerciseFormModel.swift tests/plan_exercise_draft_builder_test.swift -o /tmp/plan_draft_test && /tmp/plan_draft_test` 通过。
- `xcodebuild -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build` 通过。
- `xcodebuild ... test -only-testing:PeakLogTests` 全量通过（含更新后的 `TodayWorkoutLiveSessionTests` stub）。
- iPhone 17 Pro Max 模拟器 install/launch 通过，今日页渲染无回归（表单交互建议手动点开 + 菜单复核两个表单）。
