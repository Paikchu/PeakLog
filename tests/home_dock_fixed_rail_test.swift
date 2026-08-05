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
require(
    actionLayer.contains("static let horizontalPadding: CGFloat = 22"),
    "training actions must retain their horizontal inset"
)
// safeAreaInset 把底部安全区让给 inset 内容后不再多留空隙，按钮下沿会正好压在
// 安全区边界（Home Indicator 手势区）上。底部 CTA 必须自带这段呼吸位。
require(
    actionLayer.contains("static let bottomPadding: CGFloat = 12"),
    "bottom CTAs must keep clearance below the safe-area boundary"
)
require(
    actionLayer.contains(".padding(.bottom, BottomActionBarMetrics.bottomPadding)"),
    "training action layer must apply the shared bottom clearance"
)
let focusComponents = try String(
    contentsOf: root.appendingPathComponent("PeakLog/Views/Today/TrainingFocusComponents.swift"),
    encoding: .utf8
)
require(
    focusComponents.contains(".padding(.bottom, BottomActionBarMetrics.bottomPadding)"),
    "focus bar must apply the same bottom clearance as the action layer"
)

print("home_dockless_bottom_layer_layout_test passed")
