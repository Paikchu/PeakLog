## 目标

将 PeakLog 从“可构建的 mock / 历史线上接口架构”推进到“本地持久化 + 本地模型主链路”的可运行状态，优先修通真正的本地默认路径，而不是继续叠加兼容层。

## 技术判断

### 1. 迁移策略
- 不继续保留“线上实现 + mock 实现 + 本地实现”三套并存结构。
- 主链路直接切到本地实现，保留少量 mock 仅服务于预览或测试。
- 数据层先用单文件 JSON 持久化 actor，避免 SwiftData schema 改造在本轮引入过多不确定性。

### 2. 本地数据层设计
- 新建 `LocalAppDatabase` actor，负责读取、写入、迁移本地 JSON 状态。
- 状态模型包含：
  - profile
  - conversations
  - messages
  - workout sessions
  - running records
  - active weekly plan
- 首次启动时写入 seed data，保证页面不空白。

### 3. 服务层重构
- 用以下本地服务替换默认路径：
  - `LocalProfileService`
  - `LocalWorkoutService`
  - `LocalTrainingPlanService`
  - `LocalConversationService`
  - `OnDeviceChatService`
- 删除或停用：
  - `APIClient`
  - `LiveChatService`
  - `LiveWorkoutService`
  - `LiveProfileService`
  - `signOut` 相关语义

### 4. Foundation Models 集成方式
- 使用 `FoundationModels` 的 `LanguageModelSession` 作为聊天主路径。
- 使用 structured output 而不是正则解析，将模型输出约束为本地可执行动作结构。
- Prompt 中显式提供：
  - 当前 profile summary
  - 今日 / 本周计划摘要
  - 最近训练与 PR 摘要
  - 允许的动作边界
- 执行流：
  1. 保存用户消息
  2. 创建 `LanguageModelSession`
  3. 请求结构化响应
  4. 把动作应用到本地数据库
  5. 保存 assistant 消息和 content blocks
  6. 刷新 Today / History / Profile / Chat 读取结果

### 5. 风险控制
- `FoundationModels` 带可用性约束，因此所有调用必须包裹 availability 检测。
- 模型不可用时返回明确本地错误，不 silently fallback 到线上。
- 语音识别改为 `requiresOnDeviceRecognition = true`，但仍保留系统权限失败提示。

## 实施步骤

### Step 1. 本地数据库
- 新建本地状态模型和 JSON actor
- 加入 seed data
- 为 profile / workouts / running / plan / messages / conversation 提供 CRUD

### Step 2. 服务层落地
- 重写 `ProfileService.swift`
- 重写 `WorkoutService.swift`
- 重写 `TrainingPlanService.swift`
- 重写 `ConversationService.swift`
- 重写 `ChatService.swift`

### Step 3. 注入默认链路
- 在 `PeakLogApp` 创建共享本地容器
- 修改各 ViewModel 的默认初始化，全部切到本地服务
- 修改 `ProfileScreen` 移除 sign out 入口

### Step 4. 工程清理
- 删除 `APIClient.swift`
- 从 `project.pbxproj` 移除 Supabase package dependency
- 清掉源码中的 Supabase / Live backend 注释与命名

### Step 5. 验证
- 跑 `xcodebuild build`
- 跑 `xcodebuild test`
- 进行模拟器启动验证
- 更新日志文档，记录本轮迁移结果和遗留问题
