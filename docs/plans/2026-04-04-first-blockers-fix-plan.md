# 技术计划：修复第一批阻塞项

## 1. 问题拆解

### A. Build 阻塞
- `ProfileScreen` 的 Preview 仍引用已删除的 `AuthStateManager`
- 该问题属于迁移遗留，不影响运行时逻辑，但会阻塞整个工程构建

### B. Test 阻塞
- 现有 `tests/` 目录中的脚本测试未接入 Xcode test action
- 这些脚本以 `@main` 运行，彼此存在重复类型与协议，不能直接整体并入单个 XCTest target

## 2. 处理策略
- 对 Build 阻塞采用最小修复：只清理无效 Preview 注入
- 对 Test 阻塞采用桥接策略：新增一个正式 `PeakLogTests` XCTest target 和最小 smoke test
- 不在本轮迁移中尝试整体改写原 `tests/` 目录

## 3. 修改点
- `PeakLog/Views/Profile/ProfileScreen.swift`
- `PeakLogTests/PeakLogSmokeTests.swift`
- `PeakLog.xcodeproj/project.pbxproj`

## 4. 验证命令
- `xcodebuild build -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4'`
- `xcodebuild test -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4'`
