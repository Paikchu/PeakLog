# 2026-04-04 首页 Today 星期显示偏移修复

## 本次完成内容
- 修复首页 `TodayWorkoutViewModel` 从周计划中匹配“今天”时使用 UTC 日期的问题。
- 将 today 计划日期字符串统一切换为 `WorkoutDateFormatter`，与项目其它训练日期链路保持一致。
- 新增 `TodayWorkoutViewModelDateTests`，覆盖上海时区下本地日期与 UTC 日期不一致时的场景。

## 修改文件
- `PeakLog/ViewModels/TodayWorkoutViewModel.swift`
- `PeakLogTests/TodayWorkoutViewModelDateTests.swift`
- `docs/requirements/2026-04-04-today-weekday-offset-fix.md`
- `docs/plans/2026-04-04-today-weekday-offset-fix-plan.md`
- `docs/logs/2026-04-04-today-weekday-offset-fix.md`

## 验证
- `xcodebuild test -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4'`
  - 结果：`TEST SUCCEEDED`
