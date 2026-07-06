# 移除 Chat 相关代码

- 已确认 Today 页面没有自然语言输入入口：不渲染 `ChatInputBar`、自然语言 `TextEditor`、绑定 `viewModel.inputText` 的输入框或 AI overlay。
- 已删除独立聊天页面、聊天 ViewModel、消息气泡、输入条、语音输入、聊天滚动/键盘辅助代码。
- 已将 Today 仍需要的训练记录卡片迁到 `PeakLog/Views/Today/`。
- 已从 `TodayWorkoutViewModel` 删除 chat service、conversation service、语音识别、stream overlay、`sendAction()` 死链路。
- 已删除 `ChatMessage`、`ContentBlock`、conversation/message 本地存储和对应聊天测试。
- 已删除 Supabase `chat-send-message` Edge Function；`ai-workout-action` 保留，并改为复用 `_shared` agent/schema 模块。
- 已将跑步记录来源从 `.chat` 改为 `.agent`，保留对旧 JSON `"chat"` 的 decode 兼容。
- 已更新 README 与 architecture 文档，当前主路径为 Today 手动记录、计划执行、历史回顾和结构化 agent action。
- 验证：`swift tests/today_workout_screen_overlay_layout_test.swift`、`swift tests/today_value_edit_sheet_test.swift`、`swift tests/home_dock_navigation_test.swift` 通过。
- 验证：`node --test backend/tests/agent-system-prompt.test.mjs backend/tests/training-plan-load-type.test.mjs` 通过。
- 验证：`xcodebuild -project /Users/max/.config/superpowers/worktrees/PeakLog/remove-chat-code/PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /Users/max/.config/superpowers/worktrees/PeakLog/remove-chat-code/build CODE_SIGNING_ALLOWED=NO build` 通过。
- 验证：`xcodebuild test -project /Users/max/.config/superpowers/worktrees/PeakLog/remove-chat-code/PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /Users/max/.config/superpowers/worktrees/PeakLog/remove-chat-code/build CODE_SIGNING_ALLOWED=NO` 通过。
- 未运行：Deno 测试；本机 `deno` 不在 PATH。
