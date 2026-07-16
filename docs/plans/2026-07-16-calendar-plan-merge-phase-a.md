# 日历页与计划页融合 · Phase A（单页骨架）

日期：2026-07-16　分支：`claude/calendar-plans-merge-e0bbb8`

## 已确认的产品决策

- Calendar / Plan / Profile 三个 Tab 融合为单一训练页，**去掉底部 dock**；Profile 通过头部头像按钮以全高 sheet 打开。
- 页面以日期为"时态"路由：过去 = 只读完成记录；今天 = 现有计划页全部交互；未来 = 计划内容（Phase A 只读预览，Phase B 开放编辑）。
- 过去的日子**不显示**"计划了但未练"的信息。
- 未来可编辑范围限定在当前计划周内；周外显示"计划尚未生成"。
- AI replan 只在用户未定制当天时改写；`isUserCustomized` 标记及跳过逻辑属于 Phase B（后端字段），Phase A 不做。
- 周条（周历）**钉在页面顶部**，收起态为 7 日一行 + 展开箭头，展开态为月网格；圆点语义：实心 = 有完成记录，空心 = 今天/未来有计划安排。

## Phase A 范围（纯前端，不动后端/Service 契约）

1. `ContentView` 去 `TabView`，托管新的 `TrainingScreen`；`TrainingActionLayer` 统一为 `safeAreaInset(.bottom)` 浮动胶囊（删除 iOS 26.1 `tabViewBottomAccessory` 分支）。
2. 新建 `Views/Training/`：
   - `TrainingScreen.swift` — 钉顶头部（日期/计划标题 + 回到今天 + 头像）+ 周条 + 时态路由内容。
   - `WeekCalendarStrip.swift` — 钉顶周条（吸收 `CalendarGridView` 的 DayCell/月网格，新增计划空心点、左右滑动切周）。
   - `PastDayContent.swift` — 完成统计 pill + `HistoryCompletedTrainingSection` / 空状态（吸收 `HistoryScreen` 内容）。
   - `FutureDayContent.swift` — 计划只读预览 / 休息日 / 周外占位。
   - `PlanDayPreviewSection.swift` — 由 `HistoryPlanDaySection` 迁移改名，去掉日期/标题重复。
3. `Support/DayTense.swift` — past / today / futureInPlanWeek / futureBeyondPlan 纯函数解析（可测）。
4. `CalendarDay` 增加 `hasPlan`（默认 false）；`HistoryViewModel` 增加 `plannedDates` 派生集合与今天判断/回到今天。
5. `TodayWorkoutScreen` 移除内部 pageHeader（标题职责上移到 TrainingScreen）。
6. `ProfileScreen` 以 sheet 呈现（拖拽指示条），内容不变。
7. 删除：`HomeTab.swift`、`HistoryScreen.swift`、`CalendarGridView.swift`（内容迁移后）。
8. ViewModel **暂不合并**：`TrainingScreen` 协调 `TodayWorkoutViewModel`（今天 + live session）与 `HistoryViewModel`（日历 + 选中日数据）。合并推迟到 Phase B（未来编辑需要统一日状态时），降低本阶段回归风险。

## 本地化新增 key

`training.back_to_today`、`training.future.planned_chip`、`training.future.rest_day.title/.subtitle`、`training.future.beyond_plan.title/.subtitle`、`training.profile.open`（en + zh-Hans）。

## 测试矩阵

- 新增 `tests/day_tense_test.swift`（时态解析边界：昨天/今天/周内明天/周末日/周外/无计划）。
- 改写受影响的源码契约测试：`home_dock_navigation_test`、`home_dock_fixed_rail_test`、`history_calendar_plan_detail_visibility_test`（→ WeekCalendarStrip）、`history_plan_day_section_layout_test`（→ PlanDayPreviewSection）、`history_empty_state_test`（→ PastDayContent）、`today_workout_screen_overlay_layout_test`（如涉及 header）。
- `PeakLogTests` 中 HistoryViewModel 相关用例应保持通过（VM 未删）。
- `xcodebuild test`（iPhone 17 Pro Max，串行、先 `open -a Simulator`）+ 模拟器手测：三时态路由、周条展开/切周、回到今天、Profile sheet、专注模式进出、浮动开始/恢复训练。

## 风险与回滚

- 纯前端改动，无 Schema/RLS/Edge Function 影响；回滚 = revert 本分支。
- 已知取舍：今天完成组后周条实心点的刷新依赖重新选日/重进页面（与旧版一致），Phase B 一并处理。
