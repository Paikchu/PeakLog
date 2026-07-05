# 首页底部 Dock 与当日计划列表技术方案

## 现状判断

- `ContentView` 现在用 `showHistory` / `showProfile` 两个布尔值叠加页面。
- `TodayWorkoutScreen` 顶部包含 calendar、plus、profile 三个入口。
- `TodayWorkoutScreen` 底部固定 `ChatInputBar`，绑定 `viewModel.inputText` 和 `viewModel.sendAction()`。
- 首页计划修改能力目前通过 `TodayWorkoutViewModel.sendAction()` 进入对话流；本次从首页移除。
- `tests/today_workout_screen_overlay_layout_test.swift` 使用了旧绝对路径 `/Users/max/Developer/IOS/PeakLog`，本次应顺手改为当前仓库路径或相对路径。

## 技术方向

- App shell 改为显式 tab state：`calendar`、`plan`、`settings`。
- 不使用系统默认 `TabView` 样式直接替换，因为目标是图二那种窄 Dock，而不是全宽系统 tab bar。
- 在 `ContentView` 维护 `selectedHomeTab`，用稳定根视图切换内容，减少 overlay 布尔状态。
- 新增 `HomeDockBar`，放在 `safeAreaInset(edge: .bottom)` 或 root overlay 底部。
- iOS 26 使用 `GlassEffectContainer` + `.glassEffect(.regular.interactive(), in: .rect(cornerRadius: ...))`。
- iOS 26 以下使用 `.ultraThinMaterial` + stroke fallback。
- 加号按钮作为 `TodayWorkoutScreen` 的 floating action，右下角 `safeAreaInset` 上方，避开 Dock。
- 加号打开日记录 sheet：`DailyRecordSheet` 或复用现有记录编辑组件。
- sheet 提交后调用 workout service 写入当日记录，再触发 `viewModel.refresh()`。
- 首页不再调用 `sendAction()`，不再展示对话输入或对话流。

## 修改文件

- `PeakLog/ContentView.swift`
  - 替换 `showHistory` / `showProfile` overlay 状态。
  - 增加 `HomeTab` enum。
  - 增加底部 Dock 注入。
- `PeakLog/Views/Today/TodayWorkoutScreen.swift`
  - 删除底部固定 `ChatInputBar`。
  - 删除顶部 calendar / profile 入口。
  - 删除首页 quick actions 对话入口。
  - 保留 summary、planned、recorded。
  - 增加右下角加号按钮和日记录 sheet。
- `PeakLog/Views/Home/HomeDockBar.swift`
  - 新建底部 Dock 组件。
  - 三个 item：calendar、plan、settings。
  - 选中态用 icon + label，未选中态保留 icon 或弱 label。
- `PeakLog/Views/Today/DailyRecordSheet.swift`
  - 新建或抽取当日日记录入口。
  - 支持新增力量记录、有氧记录、自重记录。
  - 提交后调用 `TodayWorkoutViewModel` 的记录写入方法或新增薄方法封装 service 调用。
- `tests/today_workout_screen_overlay_layout_test.swift`
  - 改掉旧绝对路径。
  - 增加“不再固定渲染 ChatInputBar”的断言。
- 新增源码断言测试
  - Dock 包含 `calendar`、`figure.strengthtraining.traditional` 或等价 plan icon、`gearshape.fill`。
  - Today 页面包含 floating plus 日记录入口。

## 交互细节

- Dock item：
  - Calendar：进入 `HistoryScreen`。
  - Plan：进入 `TodayWorkoutScreen`。
  - Settings：进入 `ProfileScreen`。
- Plan tab 是默认项。
- Today 页面标题可以保留，但顶部只展示标题，不再塞导航 icon。
- 右下角加号只负责“新增/编辑日记录”。
- 手动跑步记录迁入日记录 sheet。
- quick actions 从首页移除，不再预填 prompt。

## Agent-native 边界

- 首页不再触发 agent 对话流。
- Chat 页面仍保留 agent-native 能力，后续如果要改计划，放回 Chat 或独立 agent 页面。
- 日记录 sheet 采用结构化表单，不做自然语言解析。

## 风险

- `TodayWorkoutViewModel` 由 `TodayWorkoutScreen` 持有，切 tab 如果销毁视图会触发重新加载；应让 Plan tab 的视图结构稳定。
- `TodayAIFloatingOverlay` 属于首页对话流遗留；如果首页不再触发 `sendAction()`，应从 Today 页面移除或隔离到 Chat。
- Dock 与右下角加号都在底部，必须给 ScrollView 增加足够 bottom padding。
- Liquid Glass API 仅 iOS 26 可用，必须用 `#available(iOS 26, *)` 包住。
- 旧测试路径会造成假失败，必须修。

## 验收命令

- `swift tests/today_workout_screen_overlay_layout_test.swift`
- `swift tests/chat_input_layout_constants_test.swift`
- `xcodebuild -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' build`

## 参考

- Apple `GlassEffectContainer`：iOS 26+ 用于组合多个 Liquid Glass 形状。
- Apple `GlassButtonStyle`：iOS 26+ 提供系统 glass button 样式。
- Apple SwiftUI tab navigation 指南：iOS 上 tab 导航通常落在底部；本项目因视觉目标需要自定义窄 Dock。
