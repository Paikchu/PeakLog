# 首页底部菜单固定三列实现记录

- 将 `HomeDockBar` 重构为日历、计划、设置三列固定槽位。
- 选中态标题限制在自身槽位内，不再通过自适应宽度推动相邻入口。
- “开始训练”和“继续训练”复用中间计划槽位，保留原有 `DockPlanAction` 行为。
- 保留 iOS 26 玻璃效果与低版本材质回退，并统一槽位几何令牌。
- 页面切换增加轻微位移与透明度过渡；Reduce Motion 下退化为透明度过渡。
- 新增固定布局源代码契约测试：`tests/home_dock_fixed_rail_test.swift`。
- 根据最终参考图修正选中态比例：选中背景覆盖完整列宽，菜单高度提升，图标与标题同步放大。
- 计划 CTA 从中间锚点对称展开到 148pt，不改变左右入口中心；计划就绪时保留左侧“日历”标签。
- 根据验收反馈将槽位高度从 68pt 收紧到 56pt，分隔线同步缩短到 42pt。

## 验证

- 固定布局契约测试通过：`home_dock_fixed_rail_test passed`。
- `git diff --check` 通过。
- `xcodebuild -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/PeakLogBuild CODE_SIGNING_ALLOWED=NO build` 通过。
- 使用独立 SwiftUI 预览宿主在 iPhone 17 Pro Max / iOS 26.5 Simulator 同屏检查普通态和计划就绪态。
- 参考图与实际渲染对照结果记录于 `design-qa.md`，最终结果通过。
- 未创建 commit；等待验收后确认。
