# 首页底部 Dock 与日记录改造

## 实现内容

- 首页主导航迁移到底部 Dock：Calendar、Plan、Settings。
- 首页顶部移除 calendar / profile 按钮，不再保留双入口。
- 首页移除固定 `ChatInputBar` 和 Today AI overlay。
- 首页右下角新增日记录加号入口。
- 新增 `DailyRecordSheet`，支持力量、自重、有氧三种日记录。
- 新增结构化力量记录写入能力，不再通过首页对话流创建日记录。
- 空状态文案改为引导右下角加号，不再提右上角或底部聊天框。
- iOS 26 使用 Liquid Glass Dock，旧系统使用 material fallback。

## 修改文件

- `PeakLog/ContentView.swift`
- `PeakLog/Views/Home/HomeDockBar.swift`
- `PeakLog/Views/Today/TodayWorkoutScreen.swift`
- `PeakLog/Views/Today/DailyRecordSheet.swift`
- `PeakLog/ViewModels/TodayWorkoutViewModel.swift`
- `PeakLog/Services/WorkoutService.swift`
- `PeakLog/Services/LocalAppDatabase.swift`
- `PeakLog/Models/WorkoutModels.swift`
- `PeakLog/Localizable.xcstrings`
- `tests/today_workout_screen_overlay_layout_test.swift`
- `tests/home_dock_navigation_test.swift`

## 验收

- `swift tests/today_workout_screen_overlay_layout_test.swift` 通过。
- `swift tests/home_dock_navigation_test.swift` 通过。
- `xcodebuild -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,id=8AB8FBD4-8664-4A06-B763-DDB33DBC0DB9' build` 通过。
- Build iOS Plugin 在 iPhone 17 Pro Max / iOS 26.4 上 build/run 通过。
- 运行时确认 Calendar / Settings / Plan Dock 导航可用。
- 运行时确认首页没有顶部 calendar/profile 按钮，没有底部对话框。
- 运行时确认日记录 sheet 可打开，可保存力量记录，并刷新回首页记录列表。

