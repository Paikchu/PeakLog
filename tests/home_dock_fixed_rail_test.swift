import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let content = try String(contentsOf: root.appendingPathComponent("PeakLog/ContentView.swift"), encoding: .utf8)
let theme = try String(contentsOf: root.appendingPathComponent("PeakLog/Theme/AppTheme.swift"), encoding: .utf8)
let actionLayer = try String(contentsOf: root.appendingPathComponent("PeakLog/Views/Home/TrainingActionLayer.swift"), encoding: .utf8)
let customDockURL = root.appendingPathComponent("PeakLog/Views/Home/HomeDockBar.swift")

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

require(!FileManager.default.fileExists(atPath: customDockURL.path), "custom HomeDockBar must be removed")
require(content.contains("TabView(selection: $selectedTab)"), "content view must use the native tab container")
require(!content.contains("HomeDockBar("), "content view must not render a custom bottom dock")
require(!content.contains(".padding(.bottom, 8)"), "native tab bar must own the Home Indicator spacing")
require(content.contains("TodayWorkoutScreen(viewModel: todayViewModel)\n                    .toolbarVisibility"), "focus visibility must be emitted from the plan tab content")
require(content.contains(".tabViewBottomAccessory(isEnabled: state != nil)"), "focus mode must dynamically disable the system tab accessory")
require(content.contains("TrainingActionInsetModifier"), "iOS 26.0 must retain a tab-content safe-area fallback")
require(!theme.contains("enum HomeDockMetrics"), "custom dock geometry tokens must be removed")
require(actionLayer.contains("private static let horizontalPadding: CGFloat = 22"), "training actions must retain their local horizontal inset")

print("home_native_tab_bar_layout_test passed")
