# 首页今日计划问题修复技术方案

## 目标

修复首页“今日计划”中的两个问题：

1. 重量编辑弹层无法顺利完成提交。
2. 计划中的非自重动作被错误展示为“自重”。

## 根因判断

### 1. 重量编辑无法点“完成”

根因在 iOS 交互层，不是后端保存接口。

- 首页重量编辑入口位于 `PeakLog/Views/Today/TodayWorkoutScreen.swift`
- 具体问题：
  - `TodayPlannedSetRow` 的重量编辑使用 `ValueEditSheet`
  - sheet 固定 `presentationDetents([.height(220)])`
  - `ValueEditSheet` 在 `onAppear` 时自动聚焦输入框
  - 数字键盘为 `decimalPad` / `numberPad`
- 在 iPhone 17 Pro Max + iOS 26.4 场景下，键盘升起后，220 高度弹层很容易让底部按钮区域不可点击或不可见，用户主观感受就是“没法点完成”。

附带风险：

- 聊天页的 `ExerciseCardView` 复用了同一个 `ValueEditSheet` 和相同的 `220` 高度，因此该缺陷有跨页面复用风险。

### 2. 计划全部显示为“自重”

这是双层问题，以 backend 为主，iOS 展示设计也存在语义缺陷。

#### 2.1 iOS 端语义建模缺陷

- 首页展示逻辑把 `targetWeight == nil` 直接解释成“自重”
- 这意味着只要计划未给出重量，无论动作本身是不是力量动作，UI 都会渲染成“自重”

结论：

- 当前 UI 把“没有给出目标重量”错误等同于“动作类型就是自重”

#### 2.2 backend agent 约束不足

- `backend/supabase/functions/chat-send-message/agent.ts` 当前 system prompt 明显偏向“跑步记录与跑步教练”
- 它没有对力量训练计划生成建立足够严格的 tool 使用策略和负重字段约束
- 计划 schema 虽然支持 `targetWeight` / `targetWeightUnit`，但 prompt 没有稳定要求模型：
  - 判断动作是 weighted 还是 bodyweight
  - weighted 动作在已知上下文下优先填写重量
  - 仅在明确 bodyweight 时才把重量置空

结论：

- backend 计划生成链路是本问题的主要来源
- iOS 端当前模型缺少 `exerciseType` / `loadType`，会放大 backend 的空值问题

## 修改范围评估

### 必须修改

1. `PeakLog`
2. `backend`

### 原因

- 仅修 iOS：
  - 可以解决“完成按钮点不到”
  - 但无法从根本上修复计划负重经常缺失的问题
- 仅修 backend：
  - 可以降低错误计划出现概率
  - 但 iOS 仍会把任何空重量展示成“自重”，语义依旧不正确

## 修复方案

### A. 修复重量编辑弹层交互

1. 调整 `ValueEditSheet` 的交互结构，避免固定 220 高度压缩按钮区域。
2. 给数字键盘补明确的键盘工具栏 `Done` 按钮，避免用户只能依赖底部主按钮。
3. 让弹层根据键盘和内容自然扩展，或提高 detent 高度，确保“取消/完成”始终可点击。
4. 为首页与聊天页共用组件补回归测试或最少源码断言，防止再次退化。

### B. 修复“空重量即自重”的错误语义

1. 在计划模型中新增显式负重语义字段，建议二选一：
   - `exerciseType`: `bodyweight | weighted | cardio | mixed | unknown`
   - 或 `loadType`: `bodyweight | external_load | unspecified`
2. backend 的计划 tool schema 同步新增该字段，并在计划持久化与返回 block 中透传。
3. iOS 首页展示规则改为：
   - `bodyweight` 才显示“自重”
   - `weighted + targetWeight != nil` 显示具体重量
   - `weighted + targetWeight == nil` 显示“待设置重量”或“未设置”
   - `unknown` 显示中性占位文案，而不是“自重”

### C. 修复 agent 计划生成策略

1. 重写 `chat-send-message/agent.ts` 与 `ai-workout-action` 共用的 system prompt，使其覆盖：
   - 力量训练记录
   - 训练计划生成
   - 训练计划调整
   - 跑步记录
2. 对计划生成增加明确规则：
   - 不要把未知重量默认视为 bodyweight
   - 对典型器械/杠铃/哑铃动作优先输出 `weighted`
   - 若缺少可靠重量，可保留 `targetWeight = null`，但类型必须仍为 `weighted`
3. 保持 agent-native 方案：
   - 依赖 prompt 与结构化 schema 约束
   - 不采用动作名正则或硬编码白名单来做业务判断

## 建议执行顺序

1. 先修 iOS 弹层交互，解除首页编辑阻塞。
2. 再扩展 backend plan schema 与 prompt，修复计划负重语义。
3. 最后更新 iOS 模型和渲染逻辑，按新的显式类型展示。

## 测试建议

1. iOS：
   - 首页编辑重量时，键盘弹出后仍能点击“完成”
   - 修改后能触发 `updatePlannedSet`
   - 聊天页同一组件也要复测
2. backend：
   - 增加 plan schema 测试，验证 `exerciseType/loadType` 可 round-trip
   - 增加 agent prompt 断言，确保 prompt 明确禁止“未知重量默认自重”
3. 联调：
   - 生成一个包含杠铃/哑铃/自重混合动作的计划
   - 验证首页分别显示为具体重量、未设置重量、自重

## 参考

- OpenAI 官方关于 agent 设计建议强调：使用结构化输出约束 agent 数据流，并通过清晰工具描述和 prompt 示例约束工具调用行为。
  - [Safety in building agents](https://platform.openai.com/docs/guides/agent-builder-safety)
  - [Function calling best practices](https://platform.openai.com/docs/guides/function-calling/how-do-i-ensure-the-model-calls-the-correct-function)
- AI SDK 官方文档说明 `ToolLoopAgent` 的循环与 stop condition 需要明确控制，适合继续保留当前工具式 agent 架构，但 prompt 必须与工具职责一致。
  - [AI SDK Agents: Loop Control](https://ai-sdk.dev/docs/agents/loop-control)
