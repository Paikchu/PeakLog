## 背景

PeakLog 已完成第一批阻塞项修复，当前可以正常构建和执行基础测试，但主链路仍然停留在 Mock 服务和历史线上接口抽象上，尚未达到“完全本地化、端侧运行、由 Apple Foundation Models 驱动主要 AI 功能”的目标。

本轮需求聚焦第二批迁移问题清理：
1. 清理 Supabase 与线上 API 残留
2. 建立正式的本地持久化层
3. 将聊天主链路真正接入 Apple Foundation Models

## 需求目标

### 1. 服务默认链路必须切换到本地实现
- App 默认运行时不得再依赖 `Mock*Service` 作为主路径。
- App 默认运行时不得再依赖线上 API 客户端或 Supabase SDK。
- `ContentView`、`TodayWorkoutViewModel`、`ChatViewModel`、`HistoryViewModel`、`ProfileViewModel` 的默认依赖必须指向本地服务。

### 2. 本地持久化必须覆盖核心业务数据
- 训练记录必须本地持久化，App 重启后仍可读取。
- 跑步记录必须本地持久化，App 重启后仍可读取。
- 当前活跃周计划必须本地持久化，App 重启后仍可读取。
- 用户资料、偏好设置、PR 必须本地持久化，App 重启后仍可读取。
- 会话 ID 与聊天消息必须本地持久化，App 重启后仍可读取。

### 3. 聊天主链路必须真正接入 Foundation Models
- 聊天发送消息时，主路径必须尝试调用 Apple Foundation Models。
- 模型输出不能依赖正则或硬编码表达式匹配作为主解析方案，应使用 prompt + structured output 驱动。
- 模型需要至少支持以下本地动作：
  - 记录力量训练
  - 记录跑步训练
  - 调整当天或本周计划内容
  - 更新 fitness goal summary
- 模型返回后，必须把结果写入本地持久化层，并反映到 Today / Chat / History / Profile 页面。

### 4. 不可用场景必须可处理
- 当设备或系统不支持 Foundation Models 时，App 不能崩溃。
- 当模型不可用时，用户需要看到明确错误，而不是 silently fail。
- 语音识别能力需要优先使用端侧识别。

### 5. 工程残留必须清理
- 工程中不应继续保留 Supabase Swift Package 依赖。
- 不应继续保留 `APIClient`、`Live*Service` 这类线上实现残留。
- 不应继续保留“sign out / auth session invalidation”这类后端登录语义。
- 默认头像不应再依赖远端 URL。

## 验收方案

### 功能验收
- 首次启动 App，可看到本地预置数据。
- 在聊天页输入训练描述后，能够生成 AI 回复，并将训练记录写入本地。
- 在聊天页输入跑步描述后，能够生成 AI 回复，并将跑步记录写入本地。
- 在聊天页输入调整训练计划的要求后，Today 页面和聊天中的计划内容能够更新。
- 在个人页修改偏好后，重启 App，设置仍然保留。
- 历史页能读取到本地保存的训练记录和跑步记录。

### 工程验收
- `rg` 搜索工程，不再出现 Supabase SDK、`APIClient`、`LiveChatService`、`LiveWorkoutService`、`LiveProfileService` 等残留。
- `xcodebuild build` 在 `iPhone 17 Pro Max / iOS 26.4` 上通过。
- `xcodebuild test` 在 `iPhone 17 Pro Max / iOS 26.4` 上通过。

### 体验验收
- Foundation Models 可用时，聊天主路径走本地模型。
- Foundation Models 不可用时，页面有可理解的错误提示。
- 语音识别配置优先使用端侧能力。
