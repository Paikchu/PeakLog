# 更新日志：修复本地化迁移第一批阻塞项

## 本次改动
- 移除了 `ProfileScreen` Preview 中残留的 `AuthStateManager` 注入，改为补齐现有页面实际需要的环境对象。
- 新增 `PeakLogTests` XCTest target，打通 `PeakLog` scheme 的 test action。
- 新增 `PeakLogSmokeTests`，用 `WorkoutHistoryAggregator` 聚合作为最小 smoke test，验证测试链路可执行。
- 清理了测试 target 中由于 filesystem-synced group 与手工 source entry 重复导致的重复编译 warning。

## 实际验证
- `xcodebuild build -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4'`
  - 结果：成功
- `xcodebuild test -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4'`
  - 结果：成功
- smoke test:
  - `PeakLogSmokeTests.testWorkoutHistoryAggregatorMergesSessionsForHistory()`
  - 结果：通过

## 当前状态
- 第一批阻塞项已经清理完成。
- 工程现在已经具备继续做更深入模拟器功能测试的基础条件。
- Foundation Models 本地化能力、本地持久化、Supabase 依赖清理等迁移问题仍未处理，需按后续计划继续推进。
