# 历史页空状态与页面标题一致性

- 日期入口：移除日期旁下箭头，保留独立右侧日历按钮；按钮提供 44×44 触控区域、无障碍标签和测试标识。
- 空状态：历史页无记录日期显示日期、状态标题、说明文字和“添加训练记录”入口；今天与其他日期使用不同本地化文案。
- 记录流程：空状态入口复用 `DailyRecordSheet`，保存后刷新选中日期记录和日历活跃标记。
- 标题系统：新增 `RootPageHeader` 与统一标题指标，日历、训练、设置使用相同标题字体、字号、左边距和顶部间距。
- 错误状态：历史记录加载失败时显示错误文案，不再误显示空状态。
- 本地化：新增中英文历史空状态与日历按钮文案。

## 验证

- `swiftc -parse-as-library PeakLog/Support/WorkoutDateFormatter.swift PeakLog/Support/HistoryEmptyStateContent.swift tests/history_empty_state_test.swift -o /tmp/history_empty_state_test && /tmp/history_empty_state_test`
  - 结果：`history_empty_state_test passed`
- `xcodebuild -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/PeakLogDerived CODE_SIGNING_ALLOWED=NO build`
  - 结果：`BUILD SUCCEEDED`
- `xcodebuild -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/PeakLogDerived CODE_SIGNING_ALLOWED=NO test`
  - 结果：`TEST SUCCEEDED`
- XCTest 在 iPhone 17 Pro Max clone simulator 上通过，包含 TodayPlanHeader、TodayWorkout、PeakLogSmoke 等现有测试。
- `git diff --check`：通过。

## 未完成的验证

- 尚未进行手动截图对比、VoiceOver 走查和真实模拟器交互验收。
- 历史跨月 runner 的独立命令仍需要补齐当前工程的数据库与推荐引擎依赖；XCTest 构建已覆盖相关生产代码编译。
