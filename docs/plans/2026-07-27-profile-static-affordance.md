# 个人资料 A2 紧凑分栏实施计划

## 改动边界

- `PeakLog/Views/Profile/ProfileScreen.swift`
  - 保留标题顶部留白，按 A2 调整资料信息、训练目标和区块间距。
  - 使用单一统计仪表盘替代四个并列统计项。
  - 将 PR 列表改为带上下分隔线的静态分组。
- `PeakLog/Views/Profile/StatCardView.swift`
  - 将旧统计卡组件替换为 A2 左右分栏仪表盘。
  - 左侧展示总训练量，右侧展示三行紧凑指标，不提供点击行为。
- `tests/profile_static_affordance_test.swift`
  - 锁定 A2 分栏结构、静态元素和真实入口的视觉语义边界。

## 实施顺序

- 先更新源代码契约测试，确认旧四列统计不满足 A2。
- 最小修改两个 SwiftUI View，使 A2 契约测试通过。
- 运行契约测试、相关回归测试和 iOS Simulator 构建。
- 在 iPhone 17 Pro Max、iOS 26.5 模拟器核对分栏、深浅色、静态语义和入口点击提示。

## 风险与回滚

- 风险集中在浅色/深色模式、长单位文本、动态字体和 PR 行分隔。
- 不涉及状态、数据或 Supabase。
- 回滚只需恢复两个 SwiftUI View 的视觉修饰符。
