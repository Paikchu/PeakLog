# 有氧计划目标：时长与距离填其一即可

- 触发：添加训练动作页选「跑步」后，只填距离 3km、时长留空，「保存」始终置灰。
- 分支：`claude/running-duration-distance-optional-18dd8f`

## 根因

有氧计划项从一开始就把时长当作必填、距离当作可选修饰：

- `CardioPlanExerciseInput.draft()` 用 `guard let duration = Int(...)` 开头，时长为空直接返回 `nil`，草稿为 `nil` 时保存按钮 disabled。
- `PlanExerciseDraft.cardio(...)` 复用 `CardioMetrics` 校验，而 `CardioMetrics.durationMinutes` 是非可选且要求 `> 0`——那是**实际记录**的规则（`running_workouts.duration_minutes NOT NULL`），被借用到了**计划目标**上。
- Supabase `training_plan_exercises_cardio_payload_check` 同样写死 `target_duration_minutes > 0`，即使客户端放行，只填距离的计划项也会在同步时被拒。

即「跑 5 公里」在数据模型里不是一个完整目标，必须先编一个时长。

## 改动

- **模型**：新增 `CardioPlanTarget`（`PeakLog/Models/WorkoutModels.swift`），把计划目标的校验从记录的校验里分出来——时长、距离各自可空，填了必须为正，但不能两个都空；距离仍只有跑步/骑行支持。`CardioMetrics` 原样不动，实际记录仍必须有时长。
- **草稿**：`PlanExerciseDraft.cardio` 的 `targetDurationMinutes` 改为 `Int?` 并改走 `CardioPlanTarget`；`CardioPlanExerciseInput.draft()` 分别解析两个字段，空即缺省、非空必须能解析成正数。
- **UI**（`AddPlanExerciseSheet`）：跑步/骑行的时长和距离都带「可选」占位符，下方常驻一行提示「时长、距离至少填一项」；两者都空时提示变成强调色，解释保存为什么不可用。椭圆机/爬楼机不显示距离，也就不显示这行提示。
- **Supabase**：新增迁移 `20260811093000_relax_cardio_plan_target.sql`，把 payload CHECK 放宽为「时长/距离至少其一，填了必须为正」，其余分支（力量项全空、活动类型枚举、椭圆机不带距离、RPE 区间）原样保留。
- **Edge Function**：`validator.mjs` 同步放宽——时长现在是「填了才校验」，另加一条「两个目标都没有」的结构性违规。这一步不只是为了 AI 生成：replan 会把当天既有动作重新提交一遍，只填距离的手动项若被旧校验拒绝，会连累整份计划回退。

## 未做（有意）

- **prompt 未改**：`_shared/prompt.mjs` 仍要求 AI 生成的有氧项给出正的 `targetDurationMinutes`。校验层已能接受只填距离，改 prompt 只会改变 AI 的生成倾向，不在这次修复范围内。
- **完成有氧仍需填时长**：`CardioCompletionSheet` 写的是实际记录，`running_workouts.duration_minutes` 是 `NOT NULL`。只填距离的计划完成时，时长栏会是空的、需要手动填。放宽这一侧要动记录表、历史聚合与配速口径，是另一件事。
- 未新增「目标类型」单选控件：两个字段都留着，既能只填一个，也能同时填（配速目标）。用一个二选一开关会把「30 分钟跑 5 公里」这种目标变成不可表达。

## 验证

- 通过：`node --test backend/tests/*.test.mjs`（213 → 216 项，含新增的 validator 与迁移用例）。
- 通过：`node backend/scripts/migration-ledger-check.mjs`（27 份迁移，命名/唯一性/递增无问题）。
- 未运行：`tests/` 下的独立 Swift 回归测试与 `xcodebuild`——本次开发环境无 Swift 工具链与 Xcode，相关用例（`plan_exercise_draft_builder_test`、`cardio_model_test`、`cardio_plan_ui_contract_test`）已按改动更新，需在 macOS 上补跑。
- 未运行：iPhone 17 Pro Max 模拟器手测（同上）。
- 未部署：迁移与 Edge Function 均未推送到线上。
