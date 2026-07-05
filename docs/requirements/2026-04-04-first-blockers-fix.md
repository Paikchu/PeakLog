# 需求文档：修复本地化迁移第一批阻塞项

## 1. 背景
在 Foundation Models 本地化迁移审计中，发现当前工程存在第一批阻塞项，导致无法继续进行更完整的模拟器功能验证。

## 2. 需求目标
- 修复当前导致 `xcodebuild build` 失败的工程问题。
- 修复当前导致 `xcodebuild test` 无法执行的工程配置问题。
- 为后续使用 iOS 模拟器进行更完整的功能测试打通基本链路。

## 3. 范围
- SwiftUI Preview 残留修复
- Xcode 测试 target 基础接入
- 最小 smoke test 验证

## 4. 验收标准
- [ ] `xcodebuild build -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4'` 成功
- [ ] `xcodebuild test -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4'` 成功
- [ ] 变更记录已写入 `docs/logs`
