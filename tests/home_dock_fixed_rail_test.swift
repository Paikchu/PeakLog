import Foundation

// 融合改造（2026-07-16 Phase A）后底部不再有任何 dock/tab 容器：
// 该测试固定「无自定义 dock、无 tab 容器、动作层布局参数不回退」。
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
require(!content.contains("HomeDockBar("), "content view must not render a custom bottom dock")
require(!content.contains("TabView"), "content view must not reintroduce a tab container")
require(!content.contains(".padding(.bottom, 8)"), "bottom inset spacing must stay with the safe-area inset")
require(
    content.contains(".safeAreaInset(edge: .bottom)"),
    "training action layer and focus bar must live in a bottom safe-area inset"
)
require(!theme.contains("enum HomeDockMetrics"), "custom dock geometry tokens must be removed")
require(actionLayer.contains("private static let horizontalPadding: CGFloat = 22"), "training actions must retain their local horizontal inset")

print("home_dockless_bottom_layer_layout_test passed")
