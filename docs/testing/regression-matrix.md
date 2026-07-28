# 回归测试矩阵（按模块累积）

这是「回归测试矩阵模板」（见 [AGENTS.md](../../AGENTS.md)）的累积存储：每个需求/Issue 验收通过后，把标记为「新增」的场景追加到对应模块小节；下次改动同一模块时，先把本文件里已有场景原样列入计划文档的测试矩阵并标「已有」，验收时重新跑一遍确认未回归。

不要删除已确认场景，除非对应功能被移除；功能移除时把该行移到小节末尾并标注「已随 <功能> 移除，<日期>」。

## History

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| 跨月切换日历后仍能正确选中对应日期 | `tests/history_calendar_cross_month_selection_test.swift` | 主路径 |
| 周历条只承载导航与状态圆点（实心记录/空心计划），计划明细不回流进日历组件 | `tests/history_calendar_plan_detail_visibility_test.swift` | 主路径 |
| 已完成训练的聚合统计（次数、容量等）计算正确 | `tests/history_completed_training_aggregation_test.swift` | 主路径 |
| 无历史记录时的空态展示；过去日不展示"计划了但没练"的信息 | `tests/history_empty_state_test.swift` | 空态 |
| 未来日编辑与今日计划共用卡片但无完成勾选/有氧开始；休息日与训练日均保留添加动作行；支持长按重排 | `tests/future_day_editor_contract_test.swift` | 主路径、空态 |
| 选中日期相对今天/计划周的时态解析（past/today/futureInPlanWeek/futureBeyondPlan） | `tests/day_tense_test.swift` | 主路径、空态 |
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
| 已配置力量动作后追加有氧时合并提交，未完成力量草稿阻止保存 | `tests/plan_exercise_draft_builder_test.swift`、`tests/cardio_plan_ui_contract_test.swift` | 主路径、重复提交 |

## Home

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| 无底部 dock/tab 容器；训练动作层与专注确认栏挂在底部 safe-area inset | `tests/home_dock_fixed_rail_test.swift` | 主路径 |
| 根壳托管统一 TrainingScreen；时态路由与专注模式下钉顶区显隐正确；开始训练仅在查看今天时出现 | `tests/home_dock_navigation_test.swift` | 主路径 |

## Auth · Sync

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| App 回到前台时认证网关的竞态处理 | `tests/foreground_auth_gate_race_test.swift` | 主路径、网络失败 |
| Token 刷新网络失败保留登录态，refresh 被拒绝时登出 | `PeakLogTests/AuthStateManagerTests.swift`、`PeakLogTests/SupabaseAuthProviderTests.swift` | 网络失败、权限拒绝 |
| Supabase 配置加载与校验 | `tests/supabase_config_test.swift` | 主路径 |
| SDK session 校验、local scope 退出、双击登录与并发刷新 single-flight | `PeakLogTests/SupabaseAuthProviderTests.swift`、`PeakLogTests/AuthStateManagerTests.swift` | 主路径、重复提交、迁移后兼容性 |
| Apple nonce、ID Token 交换、首次姓名 metadata、取消静默、重复提交和 Release 无邮箱入口 | `PeakLogTests/AppleSignInNonceTests.swift`、`PeakLogTests/SupabaseAuthProviderTests.swift`、`PeakLogTests/AuthStateManagerTests.swift`、`tests/apple_login_ui_contract_test.swift` | 主路径、网络失败、权限拒绝、重复提交 |
| SDK select/filter/order/limit、13 表写入、bulk-null、ignore-duplicates、scoped prune、503/520 retry 与错误映射 | `PeakLogTests/SupabaseDataClientTests.swift` | 主路径、网络失败、权限拒绝 |
| replan typed Functions 调用及全部 Outcome/HTTP/解码失败 | `PeakLogTests/PlanReplanServiceTests.swift` | 主路径、网络失败、权限拒绝 |
| 欠推送冷启动保持本地编辑、合并跨端记录；网络失败不 prune | `PeakLogTests/CloudPushFirstGuardTests.swift` | 主路径、网络失败、迁移后兼容性 |
| 快照分页读满 1001/2001 行、截断快照禁止 prune、分页中途失败零 DELETE、删除 URL 分批 | `tests/cloud_pagination_test.swift`、`PeakLogTests/SupabaseDataClientTests.swift` | 主路径、网络失败、迁移后兼容性 |
| 云端数据模型与本地模型的双向映射（roundtrip） | `tests/cloud_mapper_roundtrip_test.swift` | 主路径、迁移后兼容性 |
| 云端拉取数据与本地状态的合并策略 | `tests/cloud_pull_merge_test.swift` | 主路径、网络失败 |
| 本地状态在 Schema 迁移后仍可解码 | `tests/local_state_decode_compat_test.swift` | 迁移后兼容性 |
| 旧有氧 RPE 与记录/计划中的未知活动类型可兼容解码，新记录的 RPE 为 nil | `tests/cardio_model_test.swift`、`tests/cloud_mapper_roundtrip_test.swift`、`tests/local_state_decode_compat_test.swift` | 主路径、迁移后兼容性 |
| Service 层 mock 边界不泄漏到生产路径 | `tests/service_layer_mock_boundary_test.swift` | 主路径 |

## Profile

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| 头像卡片横排展示：头像、昵称、会员等级左对齐一行（含无头像 fallback），不含任何同步状态 | 模拟器手测 | 主路径、空态 |
| 目标区仅一张「训练目标」入口卡，无独立 Fitness Goal 文本卡；点击可打开 GoalSpecEditor | 模拟器手测 | 主路径 |
| Profile 各卡片宽度与其他 section 对齐（无双层 padding） | 模拟器手测 | 主路径 |
| 个人资料采用 A2 紧凑分栏统计；资料、统计和 PR 无伪交互边框，真实入口保留卡片与右箭头 | `tests/profile_static_affordance_test.swift`、`tests/profile_volume_display_parts_test.swift`、iPhone 17 Pro Max 浅色/深色模拟器手测 | 主路径、kg / t / lbs / k lbs、空态 |

## Exercise Library / Picker

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| 动作库搜索匹配与排序 | `tests/exercise_library_search_test.swift` | 主路径、空态 |
| 最近使用动作的选取器展示 | `tests/exercise_picker_recent_test.swift` | 主路径、空态 |
| 动作推荐逻辑 | `tests/exercise_recommendation_test.swift` | 主路径 |
| 添加训练计划直接进入统一选择器，有氧分类提供四种活动 | `tests/cardio_plan_ui_contract_test.swift` | 主路径、空态 |
| 全部、搜索与有氧筛选中的有氧项和力量项使用相同行与选择状态 | `tests/cardio_plan_ui_contract_test.swift`、iPhone 17 Pro Max 模拟器手测 | 主路径 |
| 混合选择按顺序进入配置页；返回选择器保留参数且已配置项不可重复添加 | `tests/plan_exercise_draft_builder_test.swift`、iPhone 17 Pro Max 模拟器手测 | 主路径、重复提交 |

## Localization（跨模块）

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| LocalizationManager 语言切换与 fallback | `tests/localization_manager_test.swift` | 主路径、迁移后兼容性 |
| 四个有氧名称在中文和英文中均解析为文本，不显示 `cardio.activity.*` | `tests/cardio_plan_ui_contract_test.swift`、iPhone 17 Pro Max 模拟器手测 | 主路径 |

## Live Activity

| 场景 | 验证方式 | 固定验收维度 |
|---|---|---|
| Live Activity 生命周期管理的线程/状态安全 | `tests/live_activity_manager_safety_test.swift` | 主路径 |

## 待办（已知应覆盖但目前没有固定用例）

| 模块 | 场景 | 备注 |
|---|---|---|
| — | 目前无遗留待办 | 新需求发现的待办场景写在这里，不要静默跳过 |
