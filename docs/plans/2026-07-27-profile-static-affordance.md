# 个人资料静态元素视觉语义实施计划

## 改动边界

- `PeakLog/Views/Profile/ProfileScreen.swift`
  - 在“个人资料”标题上方增加 16pt 留白，保留资料信息原有 8pt 区块间距。
  - 移除用户资料信息外层卡片背景、描边、阴影和头像额外描边。
  - 将 PR 列表改为无外层卡片壳的静态分组。
- `PeakLog/Views/Profile/StatCardView.swift`
  - 移除统计项外层卡片背景、圆角、描边和阴影。
- `tests/profile_static_affordance_test.swift`
  - 锁定静态元素与真实入口的视觉语义边界。

## 实施顺序

- 先新增源代码契约测试，确认因标题缺少额外顶部留白和现有卡片样式失败。
- 最小修改两个 SwiftUI View，使契约测试通过。
- 运行契约测试、相关回归测试和 iOS Simulator 构建。
- 在 iPhone 17 Pro Max、iOS 26.5 模拟器核对资料页留白、静态元素和入口点击提示。

## 风险与回滚

- 风险集中在浅色/深色模式下的内容层级、四列统计可读性和 PR 行分隔。
- 不涉及状态、数据或 Supabase。
- 回滚只需恢复两个 SwiftUI View 的视觉修饰符。
