# 日历页与计划页融合 · Phase A 交付记录

日期：2026-07-16　分支：`claude/calendar-plans-merge-e0bbb8`　计划：`docs/plans/2026-07-16-calendar-plan-merge-phase-a.md`

## 交付内容

- 去掉底部 dock：`ContentView` 不再持有 `TabView`，托管唯一主页面 `TrainingScreen`；训练动作层/专注确认栏统一挂在 `safeAreaInset(edge: .bottom)`（删除 iOS 26.1 `tabViewBottomAccessory` 分支）。「开始训练」仅在查看今天时出现；「训练进行中」任意日期可见，点击跳回今天并恢复专注。
- 新增 `PeakLog/Views/Training/`：
  - `TrainingScreen.swift`：钉顶头部（时态标题 + 已完成 chip / 回到今天 + 头像）+ 周条 + `DayTense` 内容路由；专注模式下钉顶区整体让位，内容锚定今天。
  - `WeekCalendarStrip.swift`：钉顶周条，收起 = 周行（横滑切周），展开 = 月网格（箭头/横滑切月）；实心点 = 有记录，空心点 = 今天/未来有计划。
  - `PastDayContent.swift`：完成统计 pill + `HistoryCompletedTrainingSection` / 空态；不显示"计划了但没练"。
  - `FutureDayContent.swift` + `PlanDayPreviewSection.swift`：周内只读预览（"计划中" chip）、休息日占位、周外"计划尚未生成"占位。
- `Support/DayTense.swift`：纯函数时态解析；`CalendarDay` 增加 `hasPlan`（默认 false，旧构造不受影响）；`HistoryViewModel` 增加 `plannedDates` / `isSelectedDateToday` / `selectedDayTense` / `selectTodayAndRefresh`。
- `TodayWorkoutScreen` 移除内部 pageHeader（标题职责上移）；`RootPageHeader` trailing 改为自适应宽度。
- Profile 经头部头像按钮以 sheet 呈现（`presentationDragIndicator`），内容不变。
- 删除：`HomeTab.swift`、`HistoryScreen.swift`、`CalendarGridView.swift`、`HistoryPlanDaySection.swift`。
- 本地化：新增 9 个 `training.*` key（en + zh-Hans），文本级插入保持 xcstrings 原格式。

## 测试与验证

- 新增 `tests/day_tense_test.swift`（9 断言，含周界/无计划/过期计划周），swiftc 通过。
  - 命令：`swiftc -parse-as-library PeakLog/Support/DayTense.swift PeakLog/Support/WorkoutDateFormatter.swift tests/day_tense_test.swift -o /tmp/day_tense_test && /tmp/day_tense_test`
- 改写并通过的源码契约测试：`home_dock_navigation_test`、`home_dock_fixed_rail_test`、`history_calendar_plan_detail_visibility_test`（→ WeekCalendarStrip）、`history_plan_day_section_layout_test`（→ PlanDayPreviewSection）、`history_empty_state_test`（→ PastDayContent，新增"过去日不显示计划"断言）、`today_workout_screen_overlay_layout_test`。
- 其余脚本测试通过：`cardio_plan_ui_contract`、`foreground_auth_gate_race`、`live_activity_manager_safety`、`plan_focus_training_mode`、`today_workout_persist_debounce`。
- `docs/testing/regression-matrix.md` 已同步（History/Home 小节 + day_tense 行）。
- xcodebuild build（iPhone 17 Pro Max）：0 error。
- xcodebuild test（iPhone 17 Pro Max，iOS 26.5，串行 + 单模拟器）：**63 passed / 0 failed**，`-skip-testing:PeakLogTests/AuthStateManagerTests`（原因见下方遗留问题）。
- 模拟器手测（iPhone 17 Pro Max，iOS 26.5，逐项点验 + 截图）：
  - 今天：计划标题"休息"+ 头像入口 + 周条（16 实底选中、17 空心计划点）+ 休息日"添加训练计划"虚线入口，无底部 dock。
  - 过去日（7/14）：日期标题 + "回到今天"胶囊 + "这天还没有记录"空态；未泄露任何计划信息。
  - 周内未来日（7/17）：头部副标题"全身训练 C · 基础力量"，"计划中" chip + 5 个动作的只读预览（无勾选框/编辑控件）。
  - 周内休息日（7/18）："休息日 / 本周计划中的休息日。"占位。
  - 月历展开：7 月网格正常，8 号实心记录点、17 号空心计划点渲染正确；周外日（7/22）显示"这一天的计划还没生成"占位。
  - "回到今天"：选中态与头部标题正确复位；头像 → Profile 全高 sheet（拖拽指示条、头像/目标/统计/PR/偏好/支持完整）。

## 追加（同日）：未来日头部只显示日期

用户确认未来日头部与过去日样式一致：仅日期标题，去掉"计划标题 · 焦点"
副标题（`futurePlanSubtitle` 移除），计划细节完全由内容区承载。顺带消除
了"新建日标题在未来日副标题里显示'今日训练'"的文案瑕疵。build 0 error，
模拟器确认 7/17 头部仅显示"7月17日 · 周五"。

## 遗留问题（非本次引入）

- **本地未推送编辑在重启后被云端拉取覆盖（数据丢失，已建独立排查任务）**：
  模拟器实验证实今日旧路径与未来日新路径同样复现（各自加动作/改重量 →
  kill 重启 → 全部回退云端旧状态），与本分支无关。机制：推送失败只把
  `hasUnpushedChanges` 留在内存，冷启动 `pull()` 以云端为真相合并。

- `PeakLogTests/AuthStateManagerTests.testConcurrentExpiredTokenRequestsUseOneRefresh`：在本机（iOS 26.4/26.5 模拟器均复现）started 后无限期卡死，三次复现，重置 CoreSimulatorService 无效；`-only-testing` 其他类全部正常，证明不是 attach/test host 环境问题，而是该并发用例自身死锁。本次 diff 未触及 auth 代码。已建独立排查任务。

- `tests/history_calendar_cross_month_selection_test.swift`：文档中的 swiftc 配方在 main 上已无法编译（肌群统计功能引入 `ExerciseLibraryEngine` 依赖链后过期），与本次改动无关；该 VM 逻辑由 `PeakLogTests` 覆盖。
- `tests/today_value_edit_sheet_test.swift`：在 main 上同样失败（断言 `ExerciseCardView` 的键盘 toolbar），与本次改动无关。

## Phase A.5 追加（同日）：未来日可编辑

用户确认后把 Phase B 的前端编辑部分提前：未来日（计划周内）改用与今日
计划完全一致的卡片 UI 与交互，仅去掉完成勾选与有氧"开始"入口；训练日与
休息日都保留虚线"添加训练计划"行（休息日添加后升级为训练日）。

- 数据层：`LocalAppDatabase.addPlannedExercises/reorderPlannedExercises`
  增加 `planDate` 参数（默认今天）；协议新增带 `planDate` 的方法，
  extension 默认回落到今天版本——既有 mock/测试替身零改动。
  改目标/加减组/删动作本就按 id 全周查找，无需改动。
- UI 层：`TodayPlannedExerciseCard`/`TodayPlannedSetRow`/`ReorderableExerciseList`
  从 TodayWorkoutScreen 抽到 `Views/Today/PlanExerciseEditingComponents.swift`
  （internal），新增 `showsCompletionControl` 开关；`PlannedCardioCard`
  新增 `showsStartAction`。
- 写路径：新增 `FutureDayPlanEditorViewModel`（独立于两个既有 VM，
  避免扩大 swiftc 契约脚本的编译面），写操作成功后回调
  `historyViewModel.loadPlan()` 全量刷新。
- `PlanDayPreviewSection` 删除；契约测试改为 `tests/future_day_editor_contract_test.swift`。

Phase A.5 验证：
- 契约测试（future_day_editor / home_dock_navigation / today_overlay /
  calendar_visibility）全部通过；xcodebuild build 0 error。
- xcodebuild test（跳过 AuthStateManagerTests，理由见遗留问题）：**63 passed / 0 failed**。
- 模拟器手测：未来日（7/17）渲染今日同款卡片（组序号/重量/次数面板、
  加减组、无勾选圈）；滚轮改重量 30→31kg 落库并回显；加组按末组模板克隆；
  休息日（7/18）保留添加行，走"选择运动 → 配置 → 保存"后当日升级为
  训练日（杠铃卧推 2×50kg×8），周条空心计划点即时出现。

## 已知取舍（Phase B 处理）

- ViewModel 未合并：`TrainingScreen` 协调三个 VM（today/history/future-editor）；Phase B 统一。
- 今天完成组后周条实心点刷新依赖重新选日/重进页面（与旧版行为一致）。
- **`isUserCustomized` 标记与 replan 跳过尚未落地（后端字段）**：在此之前，
  AI 重排/周计划重生成可能覆盖用户手动编辑过的未来日，需尽快跟进。
- 休息日添加动作后新建日的标题沿用 `today.plan.manual_day_title`
  （"今日训练"），在未来日的头部副标题里语义略歪，属文案小瑕疵。
