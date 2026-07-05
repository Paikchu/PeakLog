# 历史页移除组完成圆圈实现记录

## 需求摘要
- 移除历史/训练记录页面计划日详情中，每组动作右侧的圆圈勾选控件。

## 范围评估
- 本次仅修改 iOS 客户端视图层。
- `backend` 无需调整，Supabase Edge Function 无需部署。

## 实现概览
- 新增历史页布局回归测试，防止右侧完成图标被重新引入。
- 调整历史页计划日组件为纯文本展示，不再提供组完成按钮。
- 清理历史页日历组件中对应的无用回调传递。

## 验证
- `swift /Users/max/Developer/IOS/PeakLog/tests/history_plan_day_section_layout_test.swift`
  - 结果：通过
- `xcodebuild -project /Users/max/Developer/IOS/PeakLog/PeakLog.xcodeproj -scheme PeakLog -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' build`
  - 结果：`BUILD SUCCEEDED`
- `xcrun simctl install 8AB8FBD4-8664-4A06-B763-DDB33DBC0DB9 <PeakLog.app> && xcrun simctl launch 8AB8FBD4-8664-4A06-B763-DDB33DBC0DB9 com.max.PeakLog`
  - 结果：安装成功并启动，返回进程号 `87108`
