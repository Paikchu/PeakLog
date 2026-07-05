# 历史页周切换记录刷新计划

- 根因：`CalendarGridView` 折叠态左右箭头只调用 `goToPreviousWeek/goToNextWeek` 和 `loadCalendar()`；没有调用 `loadSessionsForSelectedDate()`。
- 可选方案：SwiftUI `task(id:)` 可在 id 改变时重启异步任务；Apple 文档确认 id 变化会取消并重启 task。
- 采用方案：保留现有 ViewModel 主导刷新模式，新增 `goToPreviousWeekAndRefresh()` / `goToNextWeekAndRefresh()`。
- 原因：当前历史页已有 `selectDateAndRefresh(_:)`，按用户动作提供显式刷新入口，风险低。
- 修改点：`HistoryViewModel` 增加周切换刷新方法，内部更新选中日期、刷新日历活跃点、刷新选中日记录。
- 修改点：`CalendarGridView` 折叠态左右箭头改为调用刷新方法；展开态换月仍只刷新日历。
- 测试：在 `history_calendar_cross_month_selection_test` 增加 2026-08-09 到 2026-08-02 的回归用例。
- 验收命令：`swiftc -parse-as-library ... tests/history_calendar_cross_month_selection_test.swift && /tmp/history_calendar_cross_month_selection_test`。
- 参考：[Apple SwiftUI task(id:)](https://developer.apple.com/documentation/swiftui/view/task%28id%3Aname%3Aexecutorpreference%3Apriority%3Afile%3Aline%3A_%3A%29)。
