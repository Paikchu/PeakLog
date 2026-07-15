import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let contentViewSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/ContentView.swift"),
    encoding: .utf8
)
let todaySource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/Views/Today/TodayWorkoutScreen.swift"),
    encoding: .utf8
)

precondition(
    contentViewSource.contains("@State private var selectedTab: HomeTab = .plan"),
    "Expected root shell to own a selected HomeTab"
)
precondition(
    contentViewSource.contains("TabView(selection: $selectedTab)"),
    "Expected root shell to use a native selection-driven TabView"
)
precondition(
    contentViewSource.contains("Tab(value: HomeTab.calendar)")
        && contentViewSource.contains("Tab(value: HomeTab.plan)")
        && contentViewSource.contains("Tab(value: HomeTab.settings)"),
    "Expected native Calendar, Plan, and Settings tabs"
)
precondition(
    contentViewSource.contains("Label(HomeTab.calendar.title, systemImage: HomeTab.calendar.symbolName)")
        && contentViewSource.contains("Label(HomeTab.plan.title, systemImage: HomeTab.plan.symbolName)")
        && contentViewSource.contains("Label(HomeTab.settings.title, systemImage: HomeTab.settings.symbolName)"),
    "Expected every native tab to show its localized text and SF Symbol"
)
precondition(
    contentViewSource.contains("TodayWorkoutScreen(viewModel: todayViewModel)\n                    .toolbarVisibility(isTrainingFocusVisible ? .hidden : .visible, for: .tabBar)"),
    "Expected focus mode to hide the native tab bar"
)
precondition(
    contentViewSource.contains("TrainingActionLayer(state:"),
    "Expected root shell to host the training action layer above the tab bar"
)
precondition(
    contentViewSource.contains("if #available(iOS 26.1, *)")
        && contentViewSource.contains(".tabViewBottomAccessory(isEnabled: state != nil)")
        && contentViewSource.contains("TrainingActionInsetModifier"),
    "Expected a dynamically disabled native accessory with an iOS 26.0 content-inset fallback"
)
precondition(
    !todaySource.contains("onShowHistory") && !todaySource.contains("onShowProfile"),
    "Expected Today header to remove top calendar/profile navigation hooks"
)

print("home_dock_navigation_test passed")
