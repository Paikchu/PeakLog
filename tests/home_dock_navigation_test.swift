import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let contentViewSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/ContentView.swift"),
    encoding: .utf8
)
let dockSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/Views/Home/HomeDockBar.swift"),
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
    contentViewSource.contains("HomeDockBar(selectedTab: $selectedTab)"),
    "Expected root shell to render the bottom dock"
)
precondition(
    dockSource.contains("case calendar") && dockSource.contains("case plan") && dockSource.contains("case settings"),
    "Expected dock to include Calendar, Plan, and Settings tabs"
)
precondition(
    dockSource.contains("GlassEffectContainer") && dockSource.contains("glassEffect"),
    "Expected dock to use Liquid Glass on iOS 26"
)
precondition(
    !todaySource.contains("onShowHistory") && !todaySource.contains("onShowProfile"),
    "Expected Today header to remove top calendar/profile navigation hooks"
)

print("home_dock_navigation_test passed")
