# 有氧动作平级化交付记录

- 需求：`docs/requirements/2026-07-16-cardio-peer-exercise-picker.md`
- 方案：`docs/plans/2026-07-16-cardio-peer-exercise-picker.md`
- 分支：`codex/cardio-peer-exercise-picker`

## 实现

- 统一力量与有氧的 Picker 项、选择状态、确认栏和列表行。
- 跑步、骑行、椭圆机、爬楼机显示可读本地化名称，不再显示翻译键。
- 计划配置页可按点击顺序混合渲染力量表单和有氧时长/距离表单。
- 计划草稿构建为整批校验，阻止重复动作和部分保存。
- 手动记录页保持力量-only 选择行为。

## 验证

- 通过：`tests/cardio_plan_ui_contract_test.swift`。
- 通过：`tests/plan_exercise_draft_builder_test.swift`、`tests/plan_edit_event_recording_test.swift`、`tests/daily_record_multi_exercise_draft_test.swift`、`tests/cardio_model_test.swift`。
- 通过：`tests/exercise_library_search_test.swift`、`tests/exercise_picker_recent_test.swift`、`tests/exercise_recommendation_test.swift`、`tests/localization_manager_test.swift`。
- iPhone 17 Pro Max（iOS 26.5）：打开添加训练计划，切换“有氧”，确认四个动作使用统一行样式；选中“跑步”后确认，进入时长和距离表单。
- `PeakLogTests/CardioPlanCompletionTests`：2/2 通过。
- 首次完整 XCTest 宿主启动卡住，按项目模拟器规程终止；Simulator.app 常驻后重试相关 XCTest 通过。

## 范围与风险

- 未改 Supabase、RLS、Schema、Edge Function 或线上数据。
- 未执行 commit、push、PR、部署。
