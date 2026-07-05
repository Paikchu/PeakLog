# 历史页移除计划详情区技术方案

## 需求理解
- 用户要求把历史页日历下方的计划详情区整块移除。
- 这是纯前端展示层改动，不应影响训练计划数据、agent 工具链或 backend 服务。

## 外部调研结论
- 参考 OpenAI 官方开发者文档中的 agent/workflow 边界建议，业务工具与 agent 负责结构化能力和状态流转，纯视觉收敛应留在前端本地实现。
- 因此本次采用“删除历史页局部视图 + 源码级回归测试”的最小方案，不引入 backend 或 prompt 层改动。

## 改动边界
- `PeakLog/Views/History/CalendarGridView.swift`
  - 移除 `selectedPlanSection` 及其在 `body` 中的渲染入口。
- `tests/history_calendar_plan_detail_visibility_test.swift`
  - 新增回归测试，防止计划详情区再次被加回。

## 不改动项
- `HistoryPlanDaySection.swift` 保持现状，不做额外删除。
- `HistoryViewModel.loadPlan()` 和顶部 `planSection` 保持不变。
- `backend` 不改，也不需要部署 Supabase。

## 实施步骤
1. 新增失败测试，锁定“日历卡片不再渲染计划详情区”。
2. 删除 `CalendarGridView` 中对应的视图代码。
3. 运行测试与 iOS 模拟器构建验证。
4. 更新实现日志。

## 验证方案
- 执行 `swift tests/history_calendar_plan_detail_visibility_test.swift`。
- 执行 `xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' build`。
