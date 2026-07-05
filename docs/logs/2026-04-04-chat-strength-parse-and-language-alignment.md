# 2026-04-04 聊天力量记录解析与 AI 语言对齐修复

## 本次完成内容
### 1. 修复 AI 回复不跟随当前语言的问题
- 将聊天链路中的 AI 输出语言来源改为“当前 App 语言优先”，不再只依赖本地 profile 中持久化的 `preferences.language`。
- 新增 `OnDeviceCoachPromptBuilder.effectiveLanguage(...)`，统一处理当前语言决策。
- 对 Foundation Models instructions 增加显式语言约束：
  - 简体中文环境下加入 `You MUST respond in Simplified Chinese.`
  - 同时加入 Apple 官方推荐的 locale 说明短语 `The person's locale is zh-Hans.`

### 2. 强化中文力量训练记录解析
- 将端侧模型 instructions / prompt 构造抽离为 `OnDeviceCoachPromptBuilder`，让 prompt 行为可测试。
- 在 instructions 中补充中文力量记录示例：
  - 输入：`完成一组硬拉 60kg，10个`
  - 明确要求：保留动作名“硬拉”，提取重量 `60kg` 和次数 `10`
- 补充约束：
  - 不得无依据把一个动作替换成另一个动作。
  - 用户明确提供重量时，不得降级成自重。
  - 中文输入时，structured output 中保留中文动作名。

### 3. 增加自动化测试
- 新增 `PeakLogTests/OnDeviceCoachPromptBuilderTests.swift`
- 覆盖内容：
  - 当前语言优先级逻辑
  - 中文环境下强制中文输出
  - 中文力量记录示例与动作保真约束

## 修改文件
- `PeakLog/Services/ChatService.swift`
- `PeakLogTests/OnDeviceCoachPromptBuilderTests.swift`
- `docs/requirements/2026-04-04-chat-strength-parse-and-language-alignment.md`
- `docs/plans/2026-04-04-chat-strength-parse-and-language-alignment-plan.md`
- `docs/logs/2026-04-04-chat-strength-parse-and-language-alignment.md`

## 验证结果
- `xcodebuild test -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4'`
  - 结果：`TEST SUCCEEDED`
- Xcode Build Plugin:
  - `BuildProject(windowtab1)`
  - 结果：构建成功

## 调研依据
- Apple Foundation Models 文档指出：
  - locale 应通过 `Instructions` 显式传入。
  - 若希望输出语言稳定，必须在 instructions 中直接要求模型使用目标语言回复。
- OpenAI Structured Outputs 文档指出：
  - 对用户生成输入，应在 prompt 中显式说明遇到歧义或不匹配时如何处理，避免模型为迎合 schema 产生错误补全。

## 当前已知非本次范围问题
- Xcode Issue Navigator 仍存在 4 条既有 Swift 6 警告：
  - `LocalAppDatabase.swift` actor isolation 相关警告 2 条
  - `KeyboardDismissAction.swift` 主线程隔离警告 1 条
  - `ChatViewModel.swift` 主线程隔离警告 1 条
- 这些警告未由本次改动引入，也未影响本轮测试通过。

