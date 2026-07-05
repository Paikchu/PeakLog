# 技术方案：聊天力量记录解析与 AI 语言对齐修复

## 问题判断
本次问题不适合用传统解析器修补，原因如下：

1. 项目明确要求 agent-native，不允许通过硬编码动作词表或正则匹配完成主解析。
2. 当前问题的根因位于 prompt/instructions 约束不足，以及“当前语言”来源选择不准确，而不是数据结构本身缺字段。

## 调研结论
- Apple Foundation Models 官方文档建议把 locale 放进 `Instructions`，并使用精确短语 `The person's locale is ...`，同时显式要求模型“必须使用指定语言回复”，否则多语言输入会导致输出语言漂移。
- OpenAI 官方 structured outputs 文档建议：面对用户生成输入时，要在 prompt 中明确说明“不兼容时如何返回空字段/澄清”，避免模型为了贴 schema 而胡乱补全。

以上结论都支持当前方案：继续使用 structured output，但把语言、locale、动作保真和重量提取约束前移到 instructions 中。

参考资料：
- Apple: `Supporting languages and locales with Foundation Models`
- Apple: `Generating content and performing tasks with Foundation Models`
- OpenAI: `Structured model outputs / Handling user-generated input`

## 实施策略
### 1. 抽离 prompt builder
- 将 `OnDeviceChatService` 中的 instructions / prompt 构造抽为内部 helper。
- 目的：
  - 让 prompt 行为可单测。
  - 避免 prompt 细节继续藏在私有方法中无法回归验证。

### 2. 修正语言来源
- 不再仅依赖持久化 profile 中的 `preferences.language`。
- 增加“当前 App 语言优先”的解析逻辑：
  - 首选 `AppLanguage.current()`。
  - profile 语言仅作为历史偏好信息，不作为 AI 当前输出语言的唯一来源。

### 3. 强化 Foundation Models instructions
- 在 `instructions` 中加入：
  - locale 精确短语。
  - 强制输出语言约束。
  - 中文力量记录示例。
  - “保留用户动作身份、不允许无依据替换动作名”约束。
  - “给出明确重量时不得回退成自重”约束。

### 4. 测试策略
- 新增 `PeakLogTests`：
  - 验证当前语言优先级。
  - 验证中文环境下 instructions 明确要求简体中文输出。
  - 验证 instructions 内包含“硬拉 60kg，10个”的结构化约束示例。
- 最后跑 `xcodebuild test`。
- 再用 iOS 26.4 / iPhone 17 Pro Max 模拟器构建验证。

## 预期修改点
- `PeakLog/Services/ChatService.swift`
- `PeakLogTests/OnDeviceCoachPromptBuilderTests.swift`
- `docs/requirements/2026-04-04-chat-strength-parse-and-language-alignment.md`
- `docs/plans/2026-04-04-chat-strength-parse-and-language-alignment-plan.md`
- `docs/logs/2026-04-04-chat-strength-parse-and-language-alignment.md`

## 风险与控制
- 风险：prompt 过长影响端侧模型稳定性。
  - 控制：保持 instructions 简洁，只保留高优先级约束和一个关键中文示例。
- 风险：当前语言优先后，与 profile 偏好出现短暂不一致。
  - 控制：AI 输出以当前 App 语言为准，优先保证用户可见结果正确；历史偏好同步可后续补强。

