# Remove Chat Code Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 移除当前不用的聊天产品代码，同时保留 Today 页面现有的手动训练记录、计划编辑、训练执行和 `ai-workout-action` 能力。

**Architecture:** 当前 Today 页面没有自然语言输入 UI：`TodayWorkoutScreen` 不渲染 `ChatInputBar`、`TextField`、`TextEditor` 或 AI overlay。残留风险集中在 `TodayWorkoutViewModel` 仍持有 chat service、conversation service、input/voice/overlay 状态和 `sendAction()` 死链路；聊天页相关文件已经不在主导航里，但仍保留源码、测试和后端 `chat-send-message` 函数。

**Tech Stack:** SwiftUI, Swift Concurrency, local JSON persistence, Supabase Edge Functions, Swift source tests, Xcode build on iOS 26.5 iPhone 17 Pro Max Simulator.

---

### Task 1: 锁定 Today 页面没有自然语言输入

**Files:**
- Read: `PeakLog/Views/Today/TodayWorkoutScreen.swift`
- Read: `PeakLog/ViewModels/TodayWorkoutViewModel.swift`
- Modify: `tests/today_workout_screen_overlay_layout_test.swift`

**Steps:**
- 保留并扩展现有源码扫描测试，断言 `TodayWorkoutScreen.swift` 不包含 `ChatInputBar(`、`TodayAIFloatingOverlay`、`TextEditor(`、绑定到 `viewModel.inputText` 的 `TextField`。
- 运行：`swift tests/today_workout_screen_overlay_layout_test.swift`
- 预期：通过，证明当前 Today 页面没有自然语言输入入口。

### Task 2: 从 TodayWorkoutViewModel 移除聊天死链路

**Files:**
- Modify: `PeakLog/ViewModels/TodayWorkoutViewModel.swift`
- Modify: `PeakLog/ContentView.swift` if compile reveals stale assumptions
- Modify: `PeakLogTests/TodayWorkoutLiveSessionTests.swift`
- Modify: `tests/today_running_coexistence_test.swift`
- Modify: `tests/today_workout_view_model_ai_action_test.swift`

**Steps:**
- 删除 `TodayAIOverlayPhase`、`inputText`、`isSending`、`latestAssistantReply`、`isOverlayVisible`、`overlayPhase`、`streamingReply`、`overlayContentBlocks`、`didPersistPlan`、`voiceInputState`。
- 删除 `chatService`、`conversationService`、`speechRecognitionService` 注入。
- 删除 `sendAction()`、语音输入方法、stream event handler、overlay block merge/apply fallback。
- 保留 Today 核心方法：`refresh()`、计划 set 编辑、手动每日记录、跑步记录、Live Activity、计划训练完成。
- 修正测试 fixture，移除 `ChatServiceProtocol` / `ConversationServiceProtocol` mock。
- 运行受影响测试：`swift tests/today_running_coexistence_test.swift`、`swift tests/today_workout_view_model_ai_action_test.swift`。
- 预期：Today 页面仍能加载计划、手动添加记录、完成 planned set；AI conversation overlay 测试应删除或改成“无入口”测试。

### Task 3: 删除独立聊天页面源码

**Files:**
- Delete: `PeakLog/ViewModels/ChatViewModel.swift`
- Delete: `PeakLog/Views/Chat/ChatScreen.swift`
- Delete: `PeakLog/Views/Chat/ChatInputBar.swift`
- Delete: `PeakLog/Views/Chat/ChatInputLayout.swift`
- Delete: `PeakLog/Views/Chat/ChatInputSubmissionAction.swift`
- Delete: `PeakLog/Views/Chat/ChatScrollKeyboardDismissBehavior.swift`
- Delete: `PeakLog/Views/Chat/KeyboardAwareChatScrollAction.swift`
- Delete: `PeakLog/Views/Chat/MultilineChatTextView.swift`
- Delete: `PeakLog/Views/Chat/MessageBubbleView.swift`
- Delete: `PeakLog/Views/Chat/VoiceWaveformView.swift`

**Steps:**
- 删除只服务聊天消息列表和输入框的视图。
- 运行：`rg -n "ChatScreen|ChatViewModel|ChatInputBar|MessageBubbleView|VoiceWaveformView" PeakLog PeakLogTests tests`
- 预期：无生产代码引用。

### Task 4: 拆分可复用训练卡片，删除聊天卡片目录依赖

**Files:**
- Move or recreate: `PeakLog/Views/Chat/WorkoutRecordCard.swift` -> `PeakLog/Views/Today/WorkoutRecordCard.swift`
- Move or recreate: `PeakLog/Views/Chat/RunningRecordCard.swift` -> `PeakLog/Views/Today/RunningRecordCard.swift`
- Evaluate delete: `PeakLog/Views/Chat/ExerciseCardView.swift`
- Evaluate delete: `PeakLog/Views/Chat/ExerciseCardPanGesture.swift`
- Evaluate delete: `PeakLog/Views/Chat/ExerciseCardSwipeGestureCoordinator.swift`
- Delete if unused: `PeakLog/Views/Chat/PRSummaryCard.swift`

**Steps:**
- `TodayWorkoutScreen` 仍使用 `WorkoutRecordCard` 和 `RunningRecordCard`，先迁到 Today 目录，保持类型名不变减少改动。
- 删除纯聊天消息渲染相关卡片。
- 运行：`rg -n "WorkoutRecordCard|RunningRecordCard|ExerciseCardView|PRSummaryCard" PeakLog tests`
- 预期：Today 只引用 Today 目录下的记录卡片；聊天目录可完全删除或只剩待迁移文件。

### Task 5: 移除 ChatMessage、ContentBlock、Conversation 存储

**Files:**
- Delete: `PeakLog/Models/ChatMessage.swift`
- Delete: `PeakLog/Models/ConversationLoadCoordinator.swift`
- Delete: `PeakLog/Services/ChatService.swift`
- Delete: `PeakLog/Services/ChatStream.swift`
- Delete: `PeakLog/Services/ConversationService.swift`
- Modify: `PeakLog/Services/LocalAppDatabase.swift`
- Modify: `PeakLog/Services/WorkoutAIActionService.swift` only if compile shows stale `ContentBlock` dependency
- Modify: `PeakLog/Models/WorkoutModels.swift`

**Steps:**
- 从 `LocalAppState` 删除 `conversations` 和 `messagesByConversation`。
- 删除 `LocalConversation`、`LocalCoachActionBundle` 到 `ChatMessage` 的转换、message seed、`fetchMessages`、`saveMessages`、`fetchOrCreateDefaultConversationId()`。
- 把 `RunningWorkoutSource.chat` 改名或迁移为 `.agent` / `.manual`；若历史 JSON 需要兼容，保留 decode alias，不再在 UI 中暴露 chat 语义。
- 从 `AppServices` 删除 `conversationService`、`chatService`。
- 运行：`rg -n "ChatMessage|ContentBlock|ConversationLoadCoordinator|ChatServiceProtocol|ChatServiceStream|messagesByConversation|LocalConversation" PeakLog`
- 预期：生产代码无结果。

### Task 6: 删除聊天专用 Swift 测试

**Files:**
- Delete: `tests/chat_view_model_*.swift`
- Delete: `tests/chat_message_pr_summary_test.swift`
- Delete: `tests/chat_input_layout_constants_test.swift`
- Delete: `tests/chat_input_submission_action_test.swift`
- Delete: `tests/chat_scroll_keyboard_dismiss_behavior_test.swift`
- Delete: `tests/keyboard_aware_chat_scroll_action_test.swift`
- Delete: `tests/conversation_load_coordinator_test.swift`
- Delete or rewrite: `tests/running_content_blocks_test.swift`
- Delete or rewrite: `tests/training_plan_content_blocks_test.swift`
- Modify: `tests/today_value_edit_sheet_test.swift`

**Steps:**
- 删除直接测试聊天 ViewModel、消息结构、输入条和 conversation loader 的测试。
- `today_value_edit_sheet_test.swift` 当前硬编码旧路径 `/Users/max/Developer/IOS/PeakLog/PeakLog/Views/Chat/ExerciseCardView.swift`，改成 Today 下真实文件或删除。
- 运行：`rg -n "ChatViewModel|ChatMessage|ContentBlock|ConversationLoadCoordinator|ChatInput|KeyboardAwareChat" tests PeakLogTests`
- 预期：没有聊天专用测试残留。

### Task 7: 删除 Supabase chat-send-message 后端函数

**Files:**
- Delete: `backend/supabase/functions/chat-send-message/`
- Delete: `backend/docs/chat-send-message-architecture.md`
- Modify: `backend/supabase/config.toml`
- Modify or delete: `backend/tests/agent-system-prompt.test.mjs`
- Modify or delete: `backend/tests/chat-send-message-plan-stream-events.test.ts`
- Modify or delete: `backend/tests/chat-send-message-streaming.test.ts`
- Modify: `backend/tests/training-plan-load-type.test.mjs`
- Modify: `backend/tests/training-plan-schema.test.ts`
- Modify: `backend/tests/running-workout-schema.test.ts`

**Steps:**
- 删除 `[functions.chat-send-message]` 配置。
- 保留 `backend/supabase/functions/ai-workout-action/`。
- 将仍被 `ai-workout-action` 复用的 schema/helper 移到 `backend/supabase/functions/_shared/`，或把测试改指向 `ai-workout-action` 自有 helper。
- 运行：`rg -n "chat-send-message" backend`
- 预期：只剩历史日志，或完全无结果；`ai-workout-action` 测试仍通过。

### Task 8: 同步文档和本次改动日志

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture/api-reference.md`
- Modify: `docs/architecture/system-architecture.md`
- Modify: `docs/architecture/business-flow.md`
- Create: `docs/logs/2026-07-06-remove-chat-code.md`

**Steps:**
- README 删除 ChatScreen、ChatViewModel、chat-send-message、messages/conversations 作为当前架构的描述。
- architecture 文档删除聊天入口，保留 `ai-workout-action` 和 Today/History/Profile 主流程。
- logs 文档记录删除范围、保留范围、验证命令。
- 运行：`rg -n "ChatScreen|ChatViewModel|chat-send-message|聊天页|messages|conversations" README.md docs/architecture docs/logs/2026-07-06-remove-chat-code.md`
- 预期：只在日志里以“已删除/历史背景”的语义出现。

### Task 9: 编译和验收

**Files:**
- Read: `PeakLog.xcodeproj/project.pbxproj`
- Read: `PeakLog/PeakLogApp.swift`
- Read: `PeakLog/ContentView.swift`

**Steps:**
- 运行 Swift 源码测试集合中仍存在的测试。
- 运行 Xcode build：
  ```bash
  xcodebuild -project /Users/max/Developer/PeakLog/PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /Users/max/Developer/PeakLog/build CODE_SIGNING_ALLOWED=NO build
  ```
- 若本机没有 iOS 26.5 runtime，先用 `xcrun simctl list runtimes` 确认，再选择可用的 iPhone 17 Pro Max runtime。
- 最终检查：
  ```bash
  rg -n "ChatScreen|ChatViewModel|ChatInputBar|chat-send-message|ChatServiceProtocol|ConversationServiceProtocol|ChatMessage|ContentBlock" PeakLog backend README.md docs/architecture tests PeakLogTests
  ```
- 预期：build succeeded；Today 页面仍能显示计划/记录；底部只有添加记录菜单和 dock；无聊天入口。

### Task 10: 提交前确认

**Files:**
- Read: `git status --short`

**Steps:**
- 汇总删除文件、修改文件、验证结果。
- 询问是否需要提交 commit。
- 用户确认后再提交，commit message 建议：`refactor: remove unused chat surface`。

---

## Agent 方案边界

- 本次删除的是未使用的聊天产品面，不删除项目未来的 agent-native 方向。
- 若之后恢复“通过对话修改页面”，建议走独立 agent action surface，而不是恢复聊天消息流。
- OpenAI Agents SDK 强调 agent loop、tools、sessions、guardrails、human-in-the-loop；AI SDK 也把 tools loop 和 `stopWhen` 作为核心控制点。
- 对 PeakLog 更合适的形态：Today 页面发起明确意图的 agent action，模型返回结构化 patch，用户确认后写入本地/后端数据。

参考：
- OpenAI Agents SDK: https://openai.github.io/openai-agents-python/
- OpenAI Agents SDK guide: https://developers.openai.com/api/docs/guides/agents
- OpenAI guardrails and human review: https://developers.openai.com/api/docs/guides/agents/guardrails-approvals
- AI SDK agents overview: https://ai-sdk.dev/docs/agents/overview
- AI SDK loop control: https://ai-sdk.dev/docs/agents/loop-control
