# 今日训练页替代聊天流方案

**目标：** 将当前 AI 聊天流页面改造为“今日日训执行页”，移除对 `conversation` 持续上下文和流式聊天的依赖，同时保留一个轻量输入框，供用户用自然语言完成“添加训练记录”“调整当天计划”“修改偏好”等单次 AI 操作。

**适用范围：**

- `PeakLog` iOS 客户端页面、ViewModel、Service、数据模型
- `peaklog-core` edge function 职责重构
- 新的单次 AI 请求协议与计划执行数据结构

**核心约束：**

- 不再维护聊天流 UI
- 不再依赖 `conversation` / `messages` 作为核心业务链路
- 不再使用流式返回
- 不采用硬编码规则或表达式匹配驱动业务判断，改为 prompt 驱动的单次任务执行
- 用户仍可通过底部输入框直接驱动训练记录和计划调整

---

## 1. 需求整理

### 1.1 页面定位变化

当前页面从：

- AI 聊天记录页

改为：

- 今日日训执行页 + AI 快捷输入框

### 1.2 页面主体要求

- 页面主体展示“当天训练计划”
- 如果当天有计划：
  - 以表格或结构化列表形式展示动作和组次
  - 用户可以直接勾选每一组是否完成
  - 用户可以手动修改重量、次数、组数
- 如果当天没有计划：
  - 展示休息日或空状态
  - 仍然保留底部 AI 输入框

### 1.3 底部输入框保留目的

输入框不再承担聊天会话展示，而是作为一次性 AI 操作入口，用于：

- 添加训练记录
- 调整当天训练计划
- 修改训练动作或组次安排
- 调整用户训练偏好

### 1.4 后端能力变化

- 不再维护 conversation 上下文
- 不再依赖消息流式返回
- 每次输入都作为单次任务处理
- 后端读取当前训练计划或用户当前数据后，通过 AI 直接生成结构化操作结果

---

## 2. 四个方向的实施计划

## 2.1 UI 改动计划

### 目标

将现有聊天流界面改造成一个以“今天训练计划”为中心的执行页，聊天框退化为页面底部的辅助输入工具。

### 需要完成的改动

- 移除消息列表作为页面主内容
- 页面顶部保留标题、日历入口、个人入口等导航结构
- 主卡片改为“Today / 今日计划”展示区
- 计划区展示：
  - 今日训练主题，例如“卧推日”
  - 今日训练目标说明，例如“卧推力量 + 上肢辅助”
  - 动作列表
  - 每组目标重量 / 次数 / 是否完成
- 每个动作支持：
  - 勾选完成
  - 修改重量
  - 修改次数
  - 修改组数
- 若当天为休息日：
  - 展示休息日卡片
  - 可展示恢复建议或轻提示
- 保留底部输入框，但只作为 AI 操作入口，不展示连续消息流

### 建议页面结构

1. Header
2. Today Plan Summary Card
3. Workout Exercise Table/List
4. Optional Notes / Coach Summary
5. Bottom AI Input Bar

### UI 实施阶段

1. 第一阶段：先保留现有导航和底部输入区，仅替换中部消息流为今日计划视图
2. 第二阶段：为动作行补齐可编辑状态、完成勾选和即时更新交互
3. 第三阶段：增加休息日、无计划、加载失败三类空状态

### UI 风险点

- 如果继续复用聊天页 ViewModel，状态会变得混乱
- 如果“勾选完成”和“编辑组次”共用消息 block 模型，维护成本会很高
- 页面应转成 plan-first，而不是 message-first

---

## 2.2 iOS 端数据结构调整计划

### 目标

把客户端的主数据源从“聊天消息 blocks”切换到“今日训练计划 + 训练执行状态 + AI 单次操作结果”。

### 需要新增或重构的核心模型

- `TodayWorkoutPlan`
  - 今日计划主对象
  - 包含日期、标题、说明、状态、动作列表
- `PlannedExercise`
  - 单个计划动作
  - 包含动作名、排序、备注、组列表
- `PlannedExerciseSet`
  - 单组处方
  - 包含目标重量、目标次数、完成状态、实际重量、实际次数
- `TodayWorkoutPageState`
  - 页面整体状态
  - 包含 loading / loaded / restDay / empty / error
- `AIWorkoutActionRequest`
  - 用户输入给 AI 的单次请求
  - 包含文本、日期、页面上下文摘要
- `AIWorkoutActionResult`
  - AI 返回的结构化结果
  - 包含 action type、计划 patch、记录写入结果、用户提示文案

### 建议状态拆分

不要继续围绕 `ChatMessage` 组织页面，建议拆成三层：

- `TodayWorkoutViewModel`
  - 管理页面展示、勾选、编辑、刷新
- `WorkoutPlanService`
  - 读取和更新当天计划
- `WorkoutAIActionService`
  - 负责把底部输入框文本发给新的单次 AI 接口

### 数据流建议

1. 页面进入时拉取当天计划
2. 页面使用 `TodayWorkoutPlan` 渲染主体
3. 用户勾选或编辑时，直接更新计划执行状态或实际记录
4. 用户通过输入框发起请求时：
   - 请求发送到单次 AI action endpoint
   - 返回结构化 patch 或新记录
   - 本地刷新当天计划

### iOS 端优先级

1. 从聊天 message 视图模型中剥离页面状态
2. 建立计划模型和动作组模型
3. 新增针对“勾选完成”和“编辑组次”的直接写库接口
4. 再接入底部 AI 单次请求

### iOS 端结论

这个需求不是简单改 UI，核心是把页面驱动模型从 `conversation/messages` 迁移到 `today plan/workout execution`。

---

## 2.3 是否需要改动 edge function 的评估与计划

### 结论

这个需求 **不仅是本地 iOS 改动**，也需要改 `peaklog-core`。

原因如下：

- 现有后端主链路是 `chat-send-message`
- 现有链路天然绑定：
  - `conversation_id`
  - `messages`
  - assistant placeholder
  - streaming / async message update
- 而你的新需求明确要求：
  - 不再维护 conversation 内容
  - 不再需要聊天流过程
  - 每次请求作为单次任务执行

因此，如果只改 iOS，不改后端，客户端仍然会被迫走旧的 conversation 语义，无法真正满足目标。

### 推荐后端改造方向

将现有“聊天函数”拆成面向任务的几个单次 action endpoint。

建议新增：

- `get-today-workout-plan`
  - 读取用户当天计划和执行状态
- `update-workout-set`
  - 更新某一组的完成状态、重量、次数
- `ai-handle-workout-action`
  - 处理底部输入框的自然语言请求
  - AI 负责识别是“添加记录”还是“修改计划”
- 可选：`refresh-today-plan`
  - 在 AI 调整后重算当天视图数据

### `ai-handle-workout-action` 应处理的任务类型

- `add_workout_record`
- `adjust_today_plan`
- `adjust_future_plan`
- `update_user_preference`
- `unknown_or_clarify`

### 后端执行模型

每次请求不再读取会话历史，而是按任务装配最小上下文：

1. 用户当前输入
2. 用户当天训练计划
3. 用户最近训练记录摘要
4. 用户偏好摘要
5. 当前日期和时区

然后让 AI 输出结构化结果：

- 意图类型
- 是否可直接执行
- 目标对象
- patch 内容或新增记录
- 返回给用户的一句话提示

### 后端实施阶段

1. 第一阶段：保留旧 `chat-send-message` 不动，新增 plan-first endpoint
2. 第二阶段：iOS 页面切到新 endpoint
3. 第三阶段：确认旧聊天流入口不再使用后，再移除或降级 conversation 相关逻辑

### 后端风险点

- 如果一步到位删除旧消息表链路，迁移风险较高
- 如果 AI 输出不做结构化约束，计划 patch 很容易不可控
- 如果“添加记录”和“调整计划”共用一套无边界 prompt，结果会不稳定

---

## 2.4 AI 请求与接口改造计划

### 目标

把当前的“流式对话 + conversation memory”改造成“无会话、单次请求、结构化返回”的 AI 工作模式。

### 新模式原则

- 每次输入都是一次独立任务
- 不要求维护强上下文
- 上下文由服务端临时拉取
- AI 负责理解和生成结构化操作
- 服务端负责校验、落库、回传结果

### 推荐接口形式

建议统一成一个 action API：

`POST /ai-handle-workout-action`

请求语义：

- `input_text`
- `target_date`
- `client_context`
  - 可选，仅放当前页面必要上下文

服务端内部拉取：

- 今日计划
- 最近记录
- 用户偏好

返回结构：

- `action_type`
- `status`
- `assistant_text`
- `plan_patch`
- `created_records`
- `updated_sets`
- `requires_refresh`

### AI Prompt 设计原则

- 不采用硬编码表达式匹配
- 不在客户端做规则分支
- 使用明确的 system prompt 约束模型职责
- 强制结构化输出
- 允许模型返回 `clarify`，但不进入长对话流，只做一次短确认

### 推荐 action 类型

- `add_record`
- `modify_today_plan`
- `modify_existing_record`
- `update_preference`
- `clarify`
- `no_op`

### 单次 AI 请求流程

1. iOS 发送输入文本
2. edge function 装配计划和用户上下文
3. AI 输出结构化 action
4. edge function 执行数据库写入或 patch
5. 返回最终结果给 iOS
6. iOS 刷新当天计划页面

### 相比当前聊天流的收益

- 页面结构更简单
- 不再依赖 conversation / messages 表作为主业务模型
- 用户目标更明确，执行链路更短
- 更适合“计划展示 + 局部 AI 调整”场景

---

## 3. 总体改造建议

### 推荐实施顺序

1. 先明确今日训练计划的数据结构
2. 在 `peaklog-core` 新增 today-plan 读取接口和 set 更新接口
3. 在 iOS 端建立新的今日训练页面模型
4. 替换聊天流主视图为 today plan 执行页
5. 再新增单次 AI action endpoint
6. 最后把底部输入框接到新的 AI action 链路

### 为什么这样排

- 先把页面主数据源改正确，再接 AI
- 先让手动执行和手动编辑闭环，再让 AI 成为增强层
- 避免出现“AI 能改计划，但页面本身还依赖消息流”的半迁移状态

---

## 4. 改动范围判断

### `PeakLog` iOS 端必须修改

- 聊天页 UI
- ChatViewModel 职责拆分
- 数据模型从 message-first 改为 plan-first
- 底部输入框提交逻辑
- 勾选与编辑交互

### `peaklog-core` 必须修改

- 新增 today plan 读取接口
- 新增 set 更新接口
- 新增单次 AI action 接口
- 逐步解除对 `conversation/messages/streaming` 的依赖

### 暂时不建议优先处理的内容

- 一开始就删除全部旧聊天表
- 一开始就重构所有历史训练相关接口
- 一开始就把未来 7 日计划、计划版本管理一次性全做完

建议先完成“今日计划执行页”的闭环，再扩展到完整 7 日计划管理。

---

## 5. 交付建议

本需求建议拆成两个开发阶段：

### Phase A：先完成可用闭环

- 今日计划页面
- 计划动作勾选
- 重量 / 次数 / 组数手动编辑
- 当天无计划 / 休息日展示
- 新的 today plan 读取与更新接口

### Phase B：补 AI 单次操作增强

- 底部输入框接新 AI action endpoint
- 支持自然语言添加记录
- 支持自然语言调整当天计划
- 支持自然语言调整偏好

---

## 6. 文档结论

你的目标不是“简化聊天页”，而是把产品核心从“聊天流记录训练”切换成“计划执行页 + AI 辅助操作”。

这意味着：

- UI 要从聊天流改成 today plan
- iOS 数据模型要从 message-first 改成 plan-first
- `peaklog-core` 需要新增非会话型接口
- AI 请求模式要改成无 conversation 的单次 action

这是一次明确的产品交互重构，不是单纯的视觉调整。
