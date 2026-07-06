# 移除 Chat 相关代码

- 目标：清掉当前暂时不用的聊天产品能力，降低 iOS 与 Supabase 后端的维护面。
- 已确认现状：主导航没有独立 Chat tab；`ContentView` 只挂载计划、日历、设置。
- 仍在运行链路：Today 页的自然语言输入依赖 `TodayWorkoutViewModel` -> `ChatServiceProtocol` -> `OnDeviceChatService`，会生成训练记录、跑步记录、7 日计划和个人目标更新。
- 可安全删除范围：`ChatScreen`、`ChatViewModel`、聊天消息列表渲染、聊天分页、聊天键盘滚动、聊天专用测试、README/architecture 里的聊天页说明。
- 待确认范围：是否一起删除 Today 页底部自然语言输入、语音输入、流式 overlay、`OnDeviceChatService`、`ChatMessage` / `ContentBlock`、本地 conversation/message 存储。
- 后端待确认范围：是否删除 `chat-send-message` Edge Function、相关测试、`backend/docs/chat-send-message-architecture.md`、`backend/supabase/config.toml` 中的函数配置。
- 保留建议：`ai-workout-action` 不应跟着删除；它是 Today 训练动作入口，不是聊天页本身。
- Agent 设计约束：若保留自然语言修改页面能力，应保留“模型 + 工具 + 明确停止条件/审批边界”的 agent 入口；OpenAI Agents SDK 与 AI SDK 都把工具、会话/状态、guardrails/HITL 作为 agent 运行时核心能力。
- 验收：Xcode project 不再引用已删 Chat 文件；`rg "ChatScreen|ChatViewModel|chat-send-message"` 只剩历史文档或没有结果；iOS build 通过；Today/History/Profile 基础流不崩；删除范围对应测试被移除或改名。
- 风险：如果连 `ChatMessage` / `ContentBlock` 一起删，训练计划预览、今日计划 overlay、跑步/力量记录预览需要改成新的领域模型，否则会出现连锁编译错误。

参考：
- OpenAI Agents SDK: https://openai.github.io/openai-agents-python/
- OpenAI Agents SDK tools: https://openai.github.io/openai-agents-python/tools/
- AI SDK agents overview: https://ai-sdk.dev/docs/agents/overview
- AI SDK loop control: https://ai-sdk.dev/docs/agents/loop-control
