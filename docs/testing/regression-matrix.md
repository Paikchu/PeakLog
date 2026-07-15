# 回归测试矩阵（按模块累积）

这是「回归测试矩阵模板」（见 [AGENTS.md](../../AGENTS.md)）的累积存储：每个需求/Issue 验收通过后，把标记为「新增」的场景追加到对应模块小节；下次改动同一模块时，先把本文件里已有场景原样列入计划文档的测试矩阵并标「已有」，验收时重新跑一遍确认未回归。

不要删除已确认场景，除非对应功能被移除；功能移除时把该行移到小节末尾并标注「已随 <功能> 移除，<日期>」。

## History

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| 跨月切换日历后仍能正确选中对应日期 | `tests/history_calendar_cross_month_selection_test.swift` | 主路径 |
| 日历上有计划的日期，详情区仍可见/可展开 | `tests/history_calendar_plan_detail_visibility_test.swift` | 主路径 |
| 已完成训练的聚合统计（次数、容量等）计算正确 | `tests/history_completed_training_aggregation_test.swift` | 主路径 |
| 无历史记录时的空态展示 | `tests/history_empty_state_test.swift` | 空态 |
| 按训练日分组的 Section 布局在不同数据量下正确 | `tests/history_plan_day_section_layout_test.swift` | 主路径 |
| HistoryViewModel 状态流与刷新逻辑 | `tests/history_running_view_model_test.swift` | 主路径、重复提交 |
| 单次训练 Session 内多条记录的聚合 | `tests/history_session_aggregation_test.swift` | 主路径 |

## Today

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| 单日多个动作的草稿构建与保存 | `tests/daily_record_multi_exercise_draft_test.swift` | 主路径、重复提交 |
| 键盘弹出时的收起动作不误触发其他手势 | `tests/keyboard_dismiss_action_test.swift` | 主路径 |
| Today 页与运行中训练（Live Activity/计时）状态共存不冲突 | `tests/today_running_coexistence_test.swift` | 主路径 |
| 数值编辑弹层的输入校验与提交 | `tests/today_value_edit_sheet_test.swift` | 主路径、重复提交 |
| 训练数据写入本地的防抖，避免高频保存 | `tests/today_workout_persist_debounce_test.swift` | 主路径 |
| 训练页浮层/overlay 在不同屏幕尺寸下的布局 | `tests/today_workout_screen_overlay_layout_test.swift` | 主路径 |
| 训练日期格式化在跨时区/跨语言下一致 | `tests/workout_date_formatter_test.swift` | 主路径、迁移后兼容性 |
| 有氧新增、完成、手动记录和卡片均无 RPE，力量组级 RPE 保留 | `tests/cardio_plan_ui_contract_test.swift`、`PeakLogTests/CardioPlanCompletionTests.swift` | 主路径、重复提交 |

## Plan

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| 目标（GoalSpec）到训练计划的映射规则 | `tests/goal_spec_mapping_test.swift` | 主路径 |
| 编辑计划时事件记录（用于后续重新生成）正确写入 | `tests/plan_edit_event_recording_test.swift` | 主路径 |
| 计划动作草稿的构建逻辑 | `tests/plan_exercise_draft_builder_test.swift` | 主路径 |
| 计划内动作重新排序后持久化正确 | `tests/plan_exercise_reorder_test.swift` | 主路径、重复提交 |
| 专注训练模式下的计划展示与交互 | `tests/plan_focus_training_mode_test.swift` | 主路径 |
| 计划文案的多语言本地化 | `tests/localized_plan_text_test.swift` | 主路径、迁移后兼容性 |
| 新增有氧计划只保存时长/距离，编辑事件和生成器输出不含 RPE | `tests/plan_exercise_draft_builder_test.swift`、`tests/plan_edit_event_recording_test.swift`、`backend/tests/` | 主路径、迁移后兼容性 |

## Home

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| 原生 Tab Bar 贴合底部安全区且无自绘 Dock 残留 | `tests/home_dock_fixed_rail_test.swift` | 主路径 |
| 日历、计划、设置原生 Tab 与训练态显隐正确 | `tests/home_dock_navigation_test.swift` | 主路径 |

## Auth · Sync

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| App 回到前台时认证网关的竞态处理 | `tests/foreground_auth_gate_race_test.swift` | 主路径、网络失败 |
| Token 有效但网络请求失败时的错误处理 | `tests/valid_token_network_error_test.swift` | 网络失败、权限拒绝 |
| Supabase 配置加载与校验 | `tests/supabase_config_test.swift` | 主路径 |
| 云端数据模型与本地模型的双向映射（roundtrip） | `tests/cloud_mapper_roundtrip_test.swift` | 主路径、迁移后兼容性 |
| 云端拉取数据与本地状态的合并策略 | `tests/cloud_pull_merge_test.swift` | 主路径、网络失败 |
| 本地状态在 Schema 迁移后仍可解码 | `tests/local_state_decode_compat_test.swift` | 迁移后兼容性 |
| 旧有氧 RPE 与未知活动类型可兼容解码，新记录的 RPE 为 nil | `tests/cardio_model_test.swift`、`tests/cloud_mapper_roundtrip_test.swift`、`tests/local_state_decode_compat_test.swift` | 主路径、迁移后兼容性 |
| Service 层 mock 边界不泄漏到生产路径 | `tests/service_layer_mock_boundary_test.swift` | 主路径 |

## Profile

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| 头像卡片横排展示：头像、昵称、会员等级左对齐一行（含无头像 fallback），不含任何同步状态 | 模拟器手测 | 主路径、空态 |
| 目标区仅一张「训练目标」入口卡，无独立 Fitness Goal 文本卡；点击可打开 GoalSpecEditor | 模拟器手测 | 主路径 |
| Profile 各卡片宽度与其他 section 对齐（无双层 padding） | 模拟器手测 | 主路径 |

## Exercise Library / Picker

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| 动作库搜索匹配与排序 | `tests/exercise_library_search_test.swift` | 主路径、空态 |
| 最近使用动作的选取器展示 | `tests/exercise_picker_recent_test.swift` | 主路径、空态 |
| 动作推荐逻辑 | `tests/exercise_recommendation_test.swift` | 主路径 |
| 添加训练计划直接进入统一选择器，有氧分类提供四种活动 | `tests/cardio_plan_ui_contract_test.swift` | 主路径、空态 |

## Localization（跨模块）

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| LocalizationManager 语言切换与 fallback | `tests/localization_manager_test.swift` | 主路径、迁移后兼容性 |

## Live Activity

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| Live Activity 生命周期管理的线程/状态安全 | `tests/live_activity_manager_safety_test.swift` | 主路径 |

## 待办（已知应覆盖但目前没有固定用例）

| 模块 | 场景 | 备注 |
|---|---|---|
| — | 目前无遗留待办 | 新需求发现的待办场景写在这里，不要静默跳过 |
