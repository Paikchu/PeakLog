# Profile 返回按钮移除计划

- 定位 Profile 的 header 实现，确认左上角箭头来自自定义按钮，不是系统 NavigationStack back button。
- 删除 ProfileScreen 的 back callback 和 header 左侧按钮。
- 保留左侧 38pt 空占位，与右侧占位对称，维持标题居中。
- ContentView 不再向 ProfileScreen 注入返回行为。
- 编译 PeakLog scheme，确认 SwiftUI 构造器调用更新后无编译错误。
