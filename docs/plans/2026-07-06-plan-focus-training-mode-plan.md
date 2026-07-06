# Plan 页专注训练模式 — 技术方案(方案 A 焦点流,不含肌群刺激强度)

需求文档:`docs/requirements/2026-07-06-plan-focus-training-mode.md`(第三节肌群刺激强度本期不做)。

## 改动总览

| 文件 | 改动 |
|---|---|
| `PeakLog/ViewModels/TodayWorkoutViewModel.swift` | Session 增加手动聚焦/跳过/Codable;指针规则重写;focus 态、休息计时、UserDefaults 持久化与恢复 |
| `PeakLog/Views/Today/TrainingSessionScreen.swift` | **删除**(全屏训练页取消) |
| `PeakLog/Views/Today/TodayWorkoutScreen.swift` | 合并专注模式:同一 ForEach 双态卡片、scrollPosition 居中、聚焦头部、确认弹窗、常亮 |
| `PeakLog/Views/Today/TrainingFocusComponents.swift` | **新增**:FocusExerciseCard / 折叠行 / TrainingFocusBar(完成按钮 + 休息倒计时) |
| `PeakLog/ContentView.swift` | dock ↔ 训练确认栏切换;dock plan 槽位支持「继续训练」 |
| `PeakLogShared/PlanLiveActivityAttributes.swift` | contentState 支持 focusedExerciseID;SharedStore 存取聚焦动作 |
| `PeakLogShared/CompletePlanSetIntent.swift` | 重建 state 时读取聚焦动作 |
| `PeakLog/Localizable.xcstrings` | 新增 training_session.* 文案(en / zh-Hans) |
| `tests/today_workout_screen_overlay_layout_test.swift` | TrainingSessionScreen 断言替换为专注模式断言 |
| `PeakLogTests/TodayWorkoutFocusFlowTests.swift` | **新增**:指针流转 / 手动切换回退 / 跳过 / 持久化恢复单测 |

## 核心逻辑

### 指针规则(moveLiveWorkoutCursor 重写)
1. 有 `manualFocusExerciseId` 且该动作仍有未完成组 → 当前动作;组 = 其第一个未完成组。
2. 手动聚焦动作已完成 → 清除锁,回到第 3 步(即"回到最早未完成")。
3. 按 plan 顺序第一个未跳过且有未完成组的动作。
4. 全部剩余均被跳过 → 第一个有未完成组的动作(含跳过)。
5. 全部完成 → 指针停在末尾,`isComplete = true`。

### 状态
- `isTrainingFocusActive: Bool`:专注模式开关;`activeLiveWorkout != nil && !isTrainingFocusActive` = 最小化(浏览模式 + 顶部"训练进行中"横幅,dock 显示「继续训练」)。
- `restEndDate: Date?`:组完成后 90s 休息倒计时(仅专注模式,自动清除,可跳过)。
- 已落库组(isAlreadyCompleted)不可在 session 内取消勾选;session 内完成的组可撤销。

### 持久化
- `activeLiveWorkout.didSet` → JSON 写入 UserDefaults(带 planDate);confirm/cancel 清除。
- `refresh()` 后:同日 + session 的组 ID 均存在于今日计划 → 恢复(合并计划中已完成组),重建 Live Activity 与观察;跨天则丢弃。

### UI / 动画
- 浏览/专注共用同一 `ForEach(plan.exercises)`,卡片按 (mode, displayedExerciseId) 切换 browse / focus-expanded / collapsed 三态 → 布局连续变化。
- `scrollPosition(id:, anchor: .center)` + `scrollTargetLayout` + 自定义 `ScrollTargetBehavior`(仅专注模式委托 viewAligned)。
- `visualEffect` 按距屏幕中心距离插值 scale/opacity(Reduce Motion 时只留 opacity)。
- 滚动停稳 250ms 防抖 → `focusLiveExercise`(停稳即切换)。
- 动作完成 → 停留 ~550ms → spring 滚动到下一动作(onChange(currentExerciseId) 延迟任务,用户滚动则取消)。
- dock 与确认栏用 move+opacity 过渡互换,复用 dockSpring。

## 验收
- `swift tests/*.swift` 全部通过(含更新后的 overlay layout 测试)。
- `xcodebuild test`(PeakLogTests)通过,新增 FocusFlow 单测覆盖指针/回退/跳过/持久化。
- iOS 26 iPhone 17 Pro Max 模拟器 build + 手动验证进入/流转/滑动切换动画。
