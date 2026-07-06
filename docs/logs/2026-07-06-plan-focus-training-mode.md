# Plan 页专注训练模式(合并 TrainingSessionScreen)

需求:`docs/requirements/2026-07-06-plan-focus-training-mode.md`(UI 方案 A 焦点流;肌群刺激强度本期不做)
Plan:`docs/plans/2026-07-06-plan-focus-training-mode-plan.md`

## 实现内容

- **删除** `TrainingSessionScreen.swift` 与 fullScreenCover;训练执行合并进 `TodayWorkoutScreen`,由 `isTrainingFocusActive` + `activeLiveWorkout` 驱动同页双态(浏览/专注)。
- **专注模式 UI**(`TrainingFocusComponents.swift` 新增):
  - 顶部紧凑头:最小化(chevron.down)、标题、n/m chip(numericText)、菜单(结束并保存/取消训练)、进度条,`safeAreaInset(.top)` + material。
  - 同一 `ForEach(plan.exercises)` 双态卡片:当前动作 `FocusExerciseCard` 展开(当前组放大高亮 + accent 指示条),其余 `FocusCollapsedExerciseRow` 折叠(完成绿勾/已跳过 chip),`visualEffect` 按距屏幕中心距离连续插值 scale/opacity。
  - 底部 `TrainingFocusBar` 替代 dock(ContentView 中 move+opacity 互换):完成第 x 组大按钮 → 组间休息 90s 倒计时(可跳过)→ 全部完成绿色「All Done · Finish & Save」。
- **指针规则**(`moveLiveWorkoutCursor` 重写):手动锁定动作优先 → 做完释放锁回到最早未完成 → 跳过的动作沉到队尾 → 全跳过时回落。滑动/点击折叠行停稳(250ms 防抖)即 `focusLiveExercise` 锁定;动作完成停留 ~550ms 再 spring 滚动流转到下一动作。
- **Session 能力**:`manualFocusExerciseId` / `skippedExerciseIds` / Codable;已落库组不可撤销、session 内完成可撤销;UserDefaults 同日持久化 + 恢复(恢复为最小化态);最小化横幅 + dock「Resume Workout」;浏览模式组勾选与 session 完成集求并显示。
- **Live Activity**:`contentState` 支持 `focusedExerciseID`(SharedStore 跨进程共享,`CompletePlanSetIntent` 重建 state 时读取);`start` 前清理系统内残留 Activity 防重复。
- **其余**:专注模式屏幕常亮;Reduce Motion 降级为 crossfade;新增 13 条 `training_session.*` 文案(en/zh-Hans)。

## 验收

- `swift tests/today_workout_screen_overlay_layout_test.swift`、`tests/plan_focus_training_mode_test.swift`(新增)、`tests/home_dock_navigation_test.swift` 通过。
- `xcodebuild test`(iPhone 17 Pro Max)全量通过,含新增 `TodayWorkoutFocusFlowTests` 7 个用例(指针流转/手动切换回退/跳过/休息计时/不可撤销/持久化恢复/取消清理)。
- 模拟器(iOS 26.5 iPhone 17 Pro Max)手动 E2E:开始训练进入专注模式 → 完成组 → 休息倒计时/跳过 → 动作完成自动流转 → 点击折叠行查看已完成动作(不夺走指针)→ 全部完成绿色按钮 → 最小化(横幅 + Resume dock)→ 恢复 → 结束并保存(plan 落库 4/4)。

## 追加:Plan 页头部重设计(方案 A)

- 新增 `Support/TodayPlanHeaderModel.swift`:`TodayPlanHeader.resolve` 智能标题降级链(计划标题 → 兜底标题"Custom Workout"/"自定义训练"时降级为 focus → 默认"今日训练";focus 与标题重复时不显示副标题);`TodayHeaderDateText.eyebrow` 按 locale 生成"7月6日 · 周一"/"Jul 6 · Mon"眉标。
- `summaryCard`:所有分支(计划/自由记录/仅跑步/空)顶部加日期眉标(计划日 accent 色,其余 muted);进度改为「进度条 + n/m 组」单行(numericText 滚动);计划全完成时进度条变绿 + 眉标旁"已完成 ✓"绿色 chip;删除原"已完成 x/y 组"独立文本行。
- 删除浏览模式的 "Today's Plan" 节标题,动作卡片直接跟随头部;专注模式顶部头标题同样走智能标题解析。
- `PlanProgressBar` 增加 `isComplete` 完成态(绿色渐变)。
- 新增文案:`today.header.default_title` / `today.header.sets_progress` / `today.header.completed`(en/zh-Hans)。
- 验收:build 通过;`TodayPlanHeaderTests` 7 个用例(降级链/去重/空白/双语眉标)+ 全量 XCTest + 相关源码断言测试通过。模拟器设备登出(Supabase 会话失效),UI 最终视觉确认待登录后进行。

## 已知余项

- 滑动吸附未用 viewAligned(它只对齐边缘无法居中),v1 为自由滚动 + 中心追踪 + 停稳展开;真机手感需再调。
- 组数少时展开卡片偏上(内容不足以滚动居中),计划内容多时不明显。
- `daily_record.load.weighted` 等既有缺失文案(AddPlanExerciseSheet)与本次无关,待补。
