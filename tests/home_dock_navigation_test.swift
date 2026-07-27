import Foundation

// 融合改造（2026-07-16 Phase A）后：底部 dock 移除，App 根壳只托管
// 统一训练页 TrainingScreen，训练动作层/专注确认栏作为底部浮层存在。
let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let contentViewSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/ContentView.swift"),
    encoding: .utf8
)
let trainingScreenSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/Views/Training/TrainingScreen.swift"),
    encoding: .utf8
)
let todaySource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/Views/Today/TodayWorkoutScreen.swift"),
    encoding: .utf8
)

precondition(
    !contentViewSource.contains("TabView") && !contentViewSource.contains("HomeTab"),
    "Expected the root shell to drop the tab container entirely"
)
precondition(
    !FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("PeakLog/Views/Home/HomeTab.swift").path),
    "Expected the HomeTab enum to be removed with the dock"
)
precondition(
    !FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("PeakLog/Views/History/HistoryScreen.swift").path),
    "Expected the standalone history screen to be merged into TrainingScreen"
)
precondition(
    contentViewSource.contains("TrainingScreen(") && contentViewSource.contains("historyViewModel: historyViewModel"),
    "Expected the root shell to host the unified TrainingScreen with both view models"
)
precondition(
    !contentViewSource.contains("tabViewBottomAccessory") && !contentViewSource.contains("toolbarVisibility"),
    "Expected the bottom bar to stop depending on tab-bar APIs"
)
precondition(
    contentViewSource.contains(".safeAreaInset(edge: .bottom)")
        && contentViewSource.contains("TrainingFocusBar(viewModel: todayViewModel)")
        && contentViewSource.contains("TrainingActionLayer(state: state, action: handleTrainingAction)"),
    "Expected a single bottom safe-area inset hosting the focus bar or the training action layer"
)
precondition(
    contentViewSource.contains("historyViewModel.isSelectedDateToday"),
    "Expected the start-training CTA to be gated on viewing today"
)
precondition(
    trainingScreenSource.contains("switch tense")
        && trainingScreenSource.contains("case .today:")
        && trainingScreenSource.contains("case .past:")
        && trainingScreenSource.contains("case .futureInPlanWeek, .futureBeyondPlan:"),
    "Expected TrainingScreen to route content by DayTense"
)
precondition(
    trainingScreenSource.contains("if !isFocusMode")
        && trainingScreenSource.contains("WeekCalendarStrip(viewModel: historyViewModel)"),
    "Expected focus mode to hide the pinned header and week strip"
)
precondition(
    !todaySource.contains("onShowHistory") && !todaySource.contains("onShowProfile"),
    "Expected Today content to keep no top calendar/profile navigation hooks"
)
precondition(
    !todaySource.contains("RootPageHeader("),
    "Expected the page title to move up into TrainingScreen's pinned header"
)
precondition(
    trainingScreenSource.contains("        case .freeRecordDay:\n            return nil"),
    "Expected today's free-record state to keep the date header subtitle-free"
)
precondition(
    trainingScreenSource.contains("        case .emptyDay:\n            return nil"),
    "Expected today's empty state to keep the date header subtitle-free"
)
precondition(
    trainingScreenSource.contains("Image(systemName: \"person\")")
        && !trainingScreenSource.contains("Image(systemName: \"person.crop.circle\")"),
    "Expected the profile control to use the simple line person symbol"
)
precondition(
    !trainingScreenSource.contains(".clipShape(Circle())"),
    "Expected the profile control to have no visible outer circle"
)

print("home_dock_navigation_test passed")
