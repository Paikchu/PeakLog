# 技术检查计划：Foundation Models 端侧化审计

## 1. 审计思路
本次不先假设“迁移已经完成”，而是按证据链自上而下核查：

1. 工程层：确认依赖、包管理、构建配置、测试配置、模拟器运行条件。
2. 架构层：确认是否仍存在网络客户端、远端服务实现、云端语义耦合。
3. 能力层：确认是否真实接入 Foundation Models、本地 tool calling、本地存储、本地语音。
4. 运行层：在 `iPhone 17 Pro Max / iOS 26.4` 模拟器上执行 build/test。
5. 文档层：把结论与问题清单记录到迁移日志。

## 2. 检查项

### A. 本地模型能力
- 搜索 `FoundationModels`、`LanguageModelSession`、`SystemLanguageModel` 等接入点。
- 判断聊天、训练计划调整、记录写入是否由真实端侧模型驱动，还是仅由 mock 数据伪装。
- 对照 Apple 官方资料判断 Foundation Models 的设备与系统约束。

### B. 本地数据能力
- 搜索 `SwiftData`、`CoreData`、`UserDefaults`、文件存储等本地持久化方案。
- 判断训练记录、计划、PR、偏好是否能跨启动持久保存。

### C. 线上依赖残留
- 搜索 `Supabase`、`APIClient`、`URLSession`、固定 URL、远端头像、登录/登出等残留。
- 判断残留是死代码、工程依赖，还是仍可能影响运行。

### D. 测试与调试
- 在 `iPhone 17 Pro Max / iOS 26.4` 模拟器上 boot 设备。
- 执行 `xcodebuild build`。
- 执行 `xcodebuild test`，确认是否存在可运行的 Xcode test action。
- 如果 build 成功，再进入安装/启动/界面验证；如果 build 失败，则记录阻塞原因。

## 3. 预期输出
- 一份基于源码与运行结果的审计结论。
- 一组按严重度分层的问题清单：
  - P0：阻塞构建/运行
  - P1：阻塞“完全本地化”目标
  - P2：削弱可靠性/可维护性/验证能力

## 4. 参考依据
- Apple 官方 Foundation Models / Apple Intelligence 资料：
  - Foundation Models 支持离线、端侧推理，但前提是 Apple Intelligence 兼容设备且已启用。
  - Apple 官方建议优先使用 prompt engineering 和 tool calling，必要时再考虑 adapter。
