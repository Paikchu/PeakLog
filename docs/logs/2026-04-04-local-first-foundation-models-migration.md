## 本次工作

目标是推进第二批本地化迁移，覆盖三类问题：
1. 移除 Supabase / 线上 API 残留
2. 建立正式的本地持久化层
3. 将聊天主链路接入 Apple Foundation Models

## 执行记录

- 已补充需求文档与技术方案。
- 已确认当前默认主路径仍依赖 `Mock*Service`，不满足本地默认运行要求。
- 已确认当前工程仍存在 `APIClient`、`Live*Service`、Supabase package、远端头像 URL、`signOut` 等迁移残留。
- 已确认本机 Xcode 26.4 SDK 内存在 `FoundationModels.framework`，可使用 `LanguageModelSession` 与 `SystemLanguageModel`。

## 已完成改动

- 新增本地 JSON 持久化层 `LocalAppDatabase`，覆盖 profile、周计划、聊天消息、力量训练、跑步记录、会话 ID。
- 新增本地默认服务：
  - `LocalProfileService`
  - `LocalWorkoutService`
  - `LocalTrainingPlanService`
  - `LocalConversationService`
  - `OnDeviceChatService`
- 默认依赖切换到本地服务，不再以 `Mock*Service` 作为主运行路径。
- 聊天主链路已接入 `FoundationModels`，使用 `LanguageModelSession` + structured output 驱动本地动作。
- 删除 `APIClient.swift`。
- 从 Xcode 工程中移除 Supabase Swift Package 依赖。
- 移除 Profile 页面中的 sign out UI 和后端退出语义。
- 默认头像改为本地占位，不再依赖远端 URL。
- 语音识别配置改为 `requiresOnDeviceRecognition = true`。
- 为 Preview 恢复独立 `MockData`，避免依赖旧聊天 mock 服务。

## 验证结果

- `xcodebuild build -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4'`
  - 结果：通过
- `xcodebuild test -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4'`
  - 结果：通过
- `xcrun simctl boot 8AB8FBD4-8664-4A06-B763-DDB33DBC0DB9`
  - 结果：通过
- `xcrun simctl install 8AB8FBD4-8664-4A06-B763-DDB33DBC0DB9 .../PeakLog.app`
  - 结果：通过
- `xcrun simctl launch 8AB8FBD4-8664-4A06-B763-DDB33DBC0DB9 com.max.PeakLog`
  - 结果：通过，进程 ID `68331`

## 当前剩余问题

- 工程仍有一批 Swift 并发告警，主要来自项目默认 `MainActor` 隔离与新本地数据层/模型类型的交互，这些告警暂未阻塞构建，但后续应继续清理。
- 当前没有通过 Build iOS Apps MCP 完成界面级自动交互，因为本次会话未暴露对应的 XcodeBuildMCP 工具；已使用 `xcodebuild + simctl` 完成等价构建、测试、安装、启动验证。
- `FoundationModels` 在真实设备可用性仍受 Apple Intelligence / 设备 / 系统条件约束；当前这轮主要完成了代码接入和不可用错误路径，而不是在模拟器上验证模型生成成功。
