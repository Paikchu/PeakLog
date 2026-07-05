# 需求文档：修复首页 Today 星期显示偏移

## 背景
当前时间为 `2026-04-04`，用户位于中国时区（`Asia/Shanghai`），按实际日期应显示星期六。但首页 Today 卡片展示为“星期日”，说明首页使用的“今天”日期与本地时区不一致。

## 目标
- 保证首页 Today/今日计划始终按当前本地时区识别当天日期。
- 保证 Today 卡片标题、训练计划匹配、星期显示三者基于同一套日期格式与时区逻辑。

## 范围
### In Scope
- 修复 `TodayWorkoutViewModel` 中从周计划匹配“今天”的日期字符串逻辑。
- 为本地时区日期计算补充回归测试。
- 补充本轮需求、技术方案与变更日志文档。

### Out of Scope
- 不改动历史页周历逻辑。
- 不改动训练计划数据结构。
- 不调整 UI 视觉样式。

## 验收标准
1. 在 `Asia/Shanghai` 时区，`2026-04-04` 首页显示为星期六。
2. 首页从周计划中挑选“今日计划”时，不再因为 UTC / 本地时区差异错拿到前一天或后一天。
3. 新增自动化测试覆盖本地时区日期字符串计算。
4. `xcodebuild test -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4'` 通过。

