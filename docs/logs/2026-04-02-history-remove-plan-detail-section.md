# 历史页移除计划详情区实现记录

## 需求摘要
- 移除历史页中日历下方的计划详情区整块内容。

## 范围评估
- 本次仅修改 iOS 客户端历史页视图层。
- `backend` 无需调整，Supabase Edge Function 无需部署。

## 实现概览
- 新增日历计划详情区可见性回归测试。
- 删除 `CalendarGridView` 中计划详情区的渲染逻辑。

## 验证
- `swift /Users/max/Developer/IOS/PeakLog/tests/history_calendar_plan_detail_visibility_test.swift`
  - 结果：通过
- `xcodebuild -project /Users/max/Developer/IOS/PeakLog/PeakLog.xcodeproj -scheme PeakLog -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' build`
  - 结果：`BUILD SUCCEEDED`
