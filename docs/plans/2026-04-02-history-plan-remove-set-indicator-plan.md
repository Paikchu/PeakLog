# 历史页移除组完成圆圈技术方案

## 需求理解
- 用户要去掉历史页计划日详情中的右侧圆圈勾选控件。
- 这是一个纯展示层收敛，不应为了 UI 改动扩展 backend 或 agent 能力边界。

## 外部调研结论
- 参考 OpenAI 官方文档中对 agent/workflow 的建议，agent 能力应聚焦在需要推理、工具调用、结构化提交的业务链路；纯展示层细节应留在前端本地实现，不应把视觉控制回灌到工具协议或后端服务。
- 因此本次采用“前端局部视图调整 + 最小回归测试”的方案，而不是改动 tool schema、edge function 或新增 prompt 约束。

## 改动边界
- `PeakLog/Views/History/HistoryPlanDaySection.swift`
  - 删除每组右侧完成按钮与图标。
  - 将行布局收敛为只读文本展示。
- `PeakLog/Views/History/CalendarGridView.swift`
  - 去掉仅为该按钮存在的完成回调传递。
- `tests/history_plan_day_section_layout_test.swift`
  - 增加源码级回归测试，防止圆圈图标被重新引入。

## 不改动项
- `HistoryViewModel.completePlannedSet(...)` 保持不动，避免影响其他页面已存在的完成流程。
- `backend` 与 Supabase 不做改动，也不需要线上部署。

## 实施步骤
1. 先补源码级失败测试，锁定“历史页不再渲染完成圆圈”。
2. 修改 `HistoryPlanDaySection`，移除按钮与图标。
3. 修改 `CalendarGridView`，移除不再使用的闭包参数。
4. 运行测试与最小构建验证。
5. 输出实现日志，说明本次仅涉及 iOS 客户端。

## 验证方案
- 执行 `swift tests/history_plan_day_section_layout_test.swift`，确认回归测试通过。
- 执行一次与历史页相关的最小编译检查，确认 SwiftUI 代码可编译。
