# 有氧动作平级化实施计划

## 方案

- 用 `ExercisePickerItem` 统一力量定义和有氧活动；稳定前缀 ID 防止跨类型碰撞。
- 用 `PlanExerciseFormItem` 维护按点击顺序排列的力量/有氧配置项；保存时由一个生成器做整批校验。
- `ExercisePickerScreen` 的全部、筛选、搜索、选中预览和确认栏都基于统一项目；仅保留力量推荐、器械筛选和自定义动作。
- `AddPlanExerciseSheet` 用一个配置路由渲染现有力量卡与有氧参数卡；`DailyRecordSheet` 继续过滤力量项目。
- `CardioActivityType.localizedTitle` 改为静态键映射，避免动态键在编译期未被字符串目录收录。

## 测试矩阵

| 模块 | 场景 | 验证方式 | 覆盖状态 |
|---|---|---|---|
| Today | 有氧新增、完成、手动记录和卡片均无 RPE，力量组级 RPE 保留 | `tests/cardio_plan_ui_contract_test.swift`、`PeakLogTests/CardioPlanCompletionTests.swift` | 已有 |
| Plan | 计划动作草稿构建、混合顺序和批量校验 | `tests/plan_exercise_draft_builder_test.swift` | 已有 / 新增 |
| Exercise Library / Picker | 搜索、最近使用和推荐逻辑 | 三个对应 `tests/` 脚本 | 已有 |
| Exercise Library / Picker | 有氧和力量共用行样式与选择状态 | `tests/cardio_plan_ui_contract_test.swift`、模拟器手测 | 新增 |
| Plan | 混合配置、返回选择器保留参数且避免重复 | `tests/plan_exercise_draft_builder_test.swift`、模拟器手测 | 新增 |
| Localization（跨模块） | 四种有氧动作解析为中英文文本 | `tests/cardio_plan_ui_contract_test.swift`、模拟器手测 | 新增 |

## 实施与验证顺序

1. 先为混合草稿、静态本地化和统一 Picker 合同补充失败测试。
2. 实现 typed item、统一列表行和混合表单；保持旧持久化契约。
3. 串行执行受影响的 standalone 测试与 `CardioPlanCompletionTests`。
4. 在 iPhone 17 Pro Max（iOS 26.5）验证“有氧”筛选、跑步选中和参数表单。
5. 记录测试矩阵和交付日志；不提交、不推送、不部署。
