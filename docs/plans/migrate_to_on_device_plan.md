# 技术演进计划: 端侧Agent与本地化改造

## 1. 架构整体调整
- **完全移除后端**：停用使用 backend 目录下 supabase edge function 的业务逻辑。所有计算、分析和 Agent 服务能力全面收敛至 PeakLog (iOS App)。
- **数据本地化**：将基于 Supabase Postgres 的云端存储切换为完全本地化的数据库方案（如 SwiftData / CoreData），用以持久化健身计划、个人 PR 及训练日志。

## 2. 端侧 Agent 与 LLM 技术方案选型
经过评估目前应用 iOS 端的大模型最佳实践，采取以下方案：
- **推理引擎**：首选 **MLX Swift** 或 Apple 下一代 **Foundation Models Framework** 构建本地核心。因其能充分利用 Apple Silicon (如 A17 Pro) 的统一内存技术，在保证低延迟的同时降低能耗。
- **模型选型设计**：下发 4-bit 量化的小参数指令跟随模型 (如 Llama-3-8B-Instruct 甚至更轻量级的语言模型)。
- **Agent 化改造**：
  - **Tool Calling 本地化**：在客户端预定义一组基于 Swift Native 的 Tool 协议（包含: `FetchPR`, `SaveWorkout`, `UpdatePreference`, `GeneratePlan`）。LLM 通过特定的 System Prompt 生成结构化指令输出，被客户端解析后触发本地数据库操作。
  - **上下文管理**：在设备端持久化保留对话历史并实施长度截断，避免超出端侧显存限制。

## 3. 具体修改模块与模块拆解
### A. PeakLog (iOS 客户端)
1. **身份认证拆除**：查找并在 `App.swift` 及相关 View 树中切除涉及 Supabase Auth （登录、注册、注销）的鉴权屏障代码，使应用默认即为合法用户状态。
2. **数据层重构替换**：创建全新的 `StorageManager`，屏蔽底层差异，代理所有原来向 Supabase 发起的增删改查。
3. **引入端侧 AgentService**：
   - 添加 MLX 依赖包。
   - 编写本地推理服务类，封装预提示词 (System Prompt)、对话消息管理和流式返回响应。
   - 实现 LLM 输出与本地方法的绑定映射层。

### B. Backend (服务端侧)
1. 将 `backend` 目录下相关代码全部标记归档并移除，不再进行维护。

## 4. 后续执行步骤（开发人员视角）
1. [ ] 修改 PeakLog 导航逻辑，清理所有 Auth 代码及UI。
2. [ ] 构建基础本地存储层基座，迁移所需的数据结构模型。
3. [ ] 整合端侧推理框架 (MLX Swift/相关API)，建立并调试 Agent 本地会话循环。
4. [ ] 在本地运行模型及对话用例，验证指令调用。最后通过 Build IOS Plugin 进行 iPhone 17 Pro Max Simulator 的真机测试验收。
