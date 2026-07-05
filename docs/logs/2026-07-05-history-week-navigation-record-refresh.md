# 历史页周切换记录刷新修复

- 修复：折叠日历左右切换周后，下方完成训练列表现在按新选中日期重新加载。
- 根因：周切换只更新 `selectedDate/displayedMonth` 并刷新日历活跃点，没有刷新 `sessions/runningRecords`。
- 代码：`HistoryViewModel` 新增 `goToPreviousWeekAndRefresh()` 和 `goToNextWeekAndRefresh()`。
- 代码：`CalendarGridView` 折叠态左右箭头改走周切换刷新方法。
- 测试：`tests/history_calendar_cross_month_selection_test.swift` 新增今天记录切到上一周记录的回归用例。
- 验证：`swiftc -parse-as-library PeakLog/Models/WorkoutModels.swift PeakLog/Models/ChatMessage.swift PeakLog/Models/TrainingPlanModels.swift PeakLog/Models/HistoryCompletedModels.swift PeakLog/Models/WorkoutHistoryAggregator.swift PeakLog/Support/WorkoutDateFormatter.swift PeakLog/ViewModels/HistoryViewModel.swift tests/history_calendar_cross_month_selection_test.swift -o /tmp/history_calendar_cross_month_selection_test && /tmp/history_calendar_cross_month_selection_test` 通过。
