import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dock = try String(contentsOf: root.appendingPathComponent("PeakLog/Views/Home/HomeDockBar.swift"), encoding: .utf8)
let content = try String(contentsOf: root.appendingPathComponent("PeakLog/ContentView.swift"), encoding: .utf8)
let theme = try String(contentsOf: root.appendingPathComponent("PeakLog/Theme/AppTheme.swift"), encoding: .utf8)

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

require(dock.contains("HomeDockMetrics"), "dock must use shared fixed geometry tokens")
require(dock.contains("frame(width: HomeDockMetrics.slotWidth"), "each tab must be constrained to the fixed slot width")
require(dock.contains(".frame(width: HomeDockMetrics.slotWidth, height: HomeDockMetrics.slotHeight)"), "selected tab background must fill its fixed column")
require(!dock.contains(".frame(width: HomeDockMetrics.minimumHitTarget, height: HomeDockMetrics.slotHeight)"), "selected tab must not shrink to the minimum hit target")
require(theme.contains("static let slotHeight: CGFloat = 56"), "dock must use the compact 56pt slot height")
require(!dock.contains("DockPlanAction") && !dock.contains("today.startPlan"), "dock must stay a pure tab rail; the training CTA lives in TrainingActionLayer")
require(dock.contains("homeDock.\\(tab.rawValue)"), "tab accessibility identifiers must remain stable")
require(content.contains("HomeDockBar(selectedTab: $selectedTab"), "content view must retain the dock outside training focus")

print("home_dock_fixed_rail_test passed")
