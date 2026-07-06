# 动作库与动作选择器实现记录

需求：`docs/requirements/2026-07-06-exercise-library-picker.md`
方案：`docs/plans/2026-07-06-exercise-library-picker-plan.md`

## 本次实现

- 新增内置动作种子库 `PeakLog/Resources/exercise_library.json`：135 个健身房动作，中英双语 + 别名 + 肌群/器械/负重方式/常用度，随 bundle 打包（文件夹同步组自动进 target）。
- 新增 `PeakLog/Models/ExerciseLibraryModels.swift`：`ExerciseDefinition` / `MuscleGroup` / `Equipment`，稳定 slug ID，宽松 decode（aliases/popularity/isCustom 可省略），归一化匹配（忽略大小写、空白、连字符）。
- 新增 `PeakLog/Services/ExerciseLibraryService.swift`：纯逻辑 `ExerciseLibraryEngine`（搜索/筛选/按肌群分组/最近使用推导/旧名解析）+ `LocalExerciseLibraryService`（bundle 加载 + 自定义合并），注册进 `AppServices`。
- `LocalAppDatabase`：`LocalAppState` 增加 `customExercises`（自定义 decode 兼容旧状态文件）、`addCustomExercise`（trim/去重/持久化）、`allStrengthSessions()`。
- 数据链路打通 `exerciseId`（全部可选，旧数据零迁移）：`TrainingPlanExercise`、`Exercise`、`PlanExerciseDraft`、`StrengthSessionDraft.ExerciseDraft`、`DailyRecordExerciseInput.sourceExerciseId`。
- 新增 `PeakLog/Views/Today/ExercisePickerScreen.swift`：无卡片通栏 Picker（搜索/肌群+器械 chips/最近使用/分组列表/多选/底部渐变 CTA/280 高自定义创建小 sheet），动画全部复用现有弹簧曲线并尊重 Reduce Motion。
- `AddPlanExerciseSheet` 重构为 Picker 先行（root=Picker → push 表单，错峰卡片入场，虚线按钮 pop 回追加）；`DailyRecordSheet` 力量模式接入同一 Picker（表单为根、push Picker，兼容有氧模式）；`ExerciseFormCard` 动作名改只读。
- 本地化：新增 `exercise_picker.*`、`muscle_group.*`、`equipment.*` 共 27 键（en/zh-Hans）；顺手补齐历史缺失的 `daily_record.load.weighted/bodyweight`、`daily_record.add_set/add_exercise` 译文。

## 验证中发现并修复的问题

1. 「最近使用」与分组列表中同一动作 id 重复导致 LazyVStack 身份冲突（行渲染丢失）→ `RecentExerciseEntry.id` 加 `recent-` 前缀。
2. 旧数据自重组 weight 存 0 而非 nil，摘要显示"上次 0 kg × 10" → 摘要格式化仅在 weight > 0 时按负重展示。
3. 归一化不含连字符导致 " PULL up " 匹配不到 "Pull-Up" → normalize 同时去除连字符。

## 测试

新增 `tests/` 逻辑测试（swiftc 编译型），源码清单统一为：

```
PeakLog/Models/{ExerciseLibraryModels,TrainingPlanModels,WorkoutModels,UserProfile,PlanExerciseFormModel,DailyRecordFormModel,HistoryCompletedModels,WorkoutHistoryAggregator}.swift
PeakLog/Services/{LocalAppDatabase,ExerciseLibraryService,ProfileService,WorkoutService,TrainingPlanService}.swift
PeakLog/Localization/AppLanguage.swift
PeakLog/Support/WorkoutDateFormatter.swift
```

- `tests/exercise_library_search_test.swift`：双语/别名/大小写/空白匹配、肌群+器械筛选、分组排序、seed+custom 合并去重、精确名解析。
- `tests/exercise_picker_recent_test.swift`：最近使用排序（最近度+频次）、摘要取最近场次最大重量组、旧自由文本名解析、未知动作排除、limit。
- `tests/local_state_decode_compat_test.swift`：无 `customExercises` 键的旧状态文件加载不丢数据；自定义动作创建/去重/空名拒绝/跨重开持久化。

结果：3 个新测试 + 受影响的 `plan_exercise_draft_builder_test`、`daily_record_multi_exercise_draft_test` 全部通过；`xcodebuild test`（18 用例）通过；iPhone 17 Pro Max 模拟器手动验证完整流程（筛选/搜索/多选/自定义创建/保存进计划）。

---

# 二期：情境推荐（同日实现）

需求：`docs/requirements/2026-07-06-exercise-picker-recommendations.md`
方案：`docs/plans/2026-07-06-exercise-picker-recommendations-plan.md`

- 新增 `PeakLog/Services/ExerciseRecommendationEngine.swift`：纯函数推荐引擎，单一入口 `recommend(context)`（未来换模型实现时调用方不动）。信号：肌群最近训练日、session 共现计数、个人频次+近度；硬排除：今日已选 + 恢复规避（大肌群 2 日、核心/全身 1 日，今日已练/已选肌群豁免）；打分分空态（需求分主导）与已选态（共现+肌群亲和主导，同肌群 ≥3 个后协同肌群上浮：胸→肩/臂、背→臂、肩→臂、腿/全身→核心）。
- `ExerciseLibraryService` 协议新增 `fetchRecommendations(todaysSelections:limit:)`，内部合并今日计划动作与今日已记录动作。
- Picker：「最近使用」区替换为「为你推荐」（键 `exercise_picker.suggested_section`，删除 `recent_section`）；`.task(id: recommendationKey)` 驱动勾选/表单变化时实时重排（自动取消过期任务）；推荐行身份加 `suggested-` 前缀避免与分组区冲突；上次数据摘要沿用 recents 查表装饰。
- 新增 `tests/exercise_recommendation_test.swift`（六场景：恢复规避与回归、核心 1 日恢复、共现+同肌群排序、饱和递进、今日豁免、冷启动+limit），编译源码清单在原清单上追加 `ExerciseRecommendationEngine.swift`。
- 验证：6 个 swiftc 逻辑测试全过、`xcodebuild test` 通过；模拟器实测——今日计划为肩（地雷管推举）时推荐区全为肩部动作、昨日练过的背被排除；连勾 3 个肩部动作后推荐区实时重排为臂部动作。
