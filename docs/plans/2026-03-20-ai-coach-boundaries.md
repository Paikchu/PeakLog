# AI 健身教练端到端架构与接口边界说明

**对应 Issue:** `PEA-14`

## 1. 结论摘要

当前代码库已经具备一条完整的“训练记录”链路：

- `PeakLog` iOS 端负责聊天输入、消息列表展示、历史记录查询、Profile/偏好展示。
- `peaklog-core` 的 `chat-send-message` edge function 负责自然语言解析、训练数据落库、PR 摘要生成。
- 数据库已具备 `profiles`、`user_preferences`、`user_stats`、`conversations`、`messages`、`workout_sessions`、`exercises`、`exercise_sets`、`exercise_prs` 等基础对象。

但“AI 健身教练”能力目前还不存在独立实现。现状缺口主要有三类：

1. 没有“教练计划”领域对象，当前只有“训练记录”。
2. 没有用于“生成计划 / 调整计划 / 记录执行反馈”的专用 API。
3. iOS 端没有教练计划专属 ViewModel / Service / 缓存模型。

因此，后续实现不应继续把“AI 教练”能力塞进现有 `chat-send-message` 单一路径，而应新增一组独立的教练域模型和 edge function，仅保留训练记录聊天链路继续服务“训练日志录入”场景。

## 2. 当前系统真实边界

### 2.1 iOS 端当前职责

依据现有实现，iOS 端当前只负责：

- 认证态管理与默认会话加载
- 发送聊天文本到 edge function
- 通过 Realtime 订阅 `messages` 变化
- 展示 `content_blocks`
- 查询历史训练与个人资料
- 直接更新 exercise / set 的名称、重量、次数

关键代码位置：

- [/Users/max/Developer/IOS/PeakLog/PeakLog/Services/SupabaseChatService.swift](/Users/max/Developer/IOS/PeakLog/PeakLog/Services/SupabaseChatService.swift)
- [/Users/max/Developer/IOS/PeakLog/PeakLog/ViewModels/ChatViewModel.swift](/Users/max/Developer/IOS/PeakLog/PeakLog/ViewModels/ChatViewModel.swift)
- [/Users/max/Developer/IOS/PeakLog/PeakLog/Services/SupabaseWorkoutService.swift](/Users/max/Developer/IOS/PeakLog/PeakLog/Services/SupabaseWorkoutService.swift)
- [/Users/max/Developer/IOS/PeakLog/PeakLog/Services/SupabaseProfileService.swift](/Users/max/Developer/IOS/PeakLog/PeakLog/Services/SupabaseProfileService.swift)

### 2.2 后端当前职责

依据现有实现，edge function 当前负责：

- 校验用户身份和 `conversation_id`
- 保存用户消息和 assistant placeholder
- 调用 DeepSeek 做训练解析
- 将解析结果写入 `workout_sessions / exercises / exercise_sets`
- 刷新 `exercise_prs`
- 回写 `messages.content_blocks`

关键代码位置：

- [/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts](/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts)
- [/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/pr-summary.ts](/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/pr-summary.ts)

### 2.3 当前数据流

现有数据流可以分成四段：

1. 用户输入训练自然语言
2. iOS 调用 `chat-send-message`
3. edge function 解析后写入 `messages` 和训练表
4. iOS 通过 Realtime 收到 assistant message 更新并展示

这条链路适合“记录已完成训练”，不适合直接承载“未来计划生成与调整”，原因如下：

- 请求语义混杂：记录训练和生成教练计划不是同一类命令。
- 返回结构不稳定：当前 `content_blocks` 只覆盖 `text`、`workout_record`、`pr_summary`。
- 数据归属不清：计划属于长期对象，不应仅挂在聊天消息 JSON 上。
- 生命周期不同：训练记录一次性落库；训练计划需要版本、状态、反馈、重算。

## 3. 推荐职责划分

### 3.1 iOS 端职责

AI 教练场景下，iOS 端应负责：

- 教练入口页和计划详情页展示
- 收集用户输入：目标、训练频率、器械条件、受伤限制、偏好肌群
- 发起计划生成、计划调整、训练反馈提交
- 本地缓存当前计划摘要和最近一次生成结果
- 展示计划生成中、生成失败、计划过期、需重新生成等状态
- 在训练执行后，将反馈提交到后端，而不是在端上做规则推导

不应放在 iOS 端的职责：

- 基于历史训练数据计算周训练量、疲劳、动作推荐
- 大模型 prompt 编排
- 自然语言计划调整解析
- 计划版本合并与持久化
- “是否应该 deload / 换动作 / 提重”的核心决策逻辑

### 3.2 Supabase edge function 职责

后端应负责：

- 聚合训练历史、PR、用户画像、偏好和最近反馈
- 生成标准化教练上下文
- 调用 LLM 生成训练计划
- 解析“下周把深蹲降一点”这类自然语言调整请求
- 将调整意图映射为结构化 patch
- 产出计划版本、周/天训练项、动作处方
- 写入反馈结果并更新计划状态
- 统一返回错误码和可展示的失败原因

### 3.3 数据库职责

数据库负责：

- 保存训练历史事实数据
- 保存当前生效计划与历史版本
- 保存每日执行反馈
- 保存计划调整请求与处理结果
- 保存可追踪的审计记录

## 4. 领域对象设计

当前已有对象：

- `profiles`
- `user_preferences`
- `user_stats`
- `exercise_prs`
- `workout_sessions`
- `exercises`
- `exercise_sets`
- `messages`
- `conversations`

为 AI 教练建议新增对象。

### 4.1 coach_profiles

用途：保存教练生成所需的长期偏好，不与通用 `user_preferences` 混在一起。

建议字段：

- `id`
- `user_id`
- `primary_goal`，如 `muscle_gain | strength | fat_loss | general_fitness`
- `experience_level`，如 `beginner | intermediate | advanced`
- `days_per_week`
- `session_minutes`
- `equipment_access`，jsonb 数组
- `injuries_limitations`，jsonb 数组
- `preferred_split`
- `disliked_exercises`，jsonb 数组
- `updated_at`

### 4.2 coach_plans

用途：计划主表，一条记录代表一个版本化计划。

建议字段：

- `id`
- `user_id`
- `status`，如 `draft | active | superseded | archived`
- `goal`
- `start_date`
- `end_date`
- `weeks`
- `source`，如 `ai_generated | ai_adjusted | manual`
- `based_on_plan_id`
- `summary_text`
- `generation_context_json`
- `created_at`
- `updated_at`

### 4.3 coach_plan_days

用途：拆分到每日训练模板，便于 iOS 展示和打卡。

建议字段：

- `id`
- `plan_id`
- `week_index`
- `day_index`
- `title`
- `focus`
- `estimated_duration_minutes`
- `notes`

### 4.4 coach_plan_exercises

用途：保存每日计划动作处方。

建议字段：

- `id`
- `plan_day_id`
- `order_index`
- `exercise_name`
- `normalized_name`
- `prescription_type`，如 `sets_reps | reps_only | rpe | amrap`
- `target_sets`
- `target_reps`
- `target_weight`
- `weight_unit`
- `target_rpe`
- `rest_seconds`
- `notes`
- `swap_candidates_json`

### 4.5 coach_feedback_events

用途：记录用户每次训练执行后的反馈，用于下一次生成和调整。

建议字段：

- `id`
- `user_id`
- `plan_id`
- `plan_day_id`
- `workout_session_id`
- `completed` boolean
- `difficulty_score`，1-5
- `energy_score`，1-5
- `pain_points_json`
- `freeform_feedback`
- `created_at`

### 4.6 coach_adjustment_requests

用途：记录自然语言计划调整请求及解析结果。

建议字段：

- `id`
- `user_id`
- `plan_id`
- `source_message_id`，可为空
- `request_text`
- `parsed_intent_json`
- `status`，如 `processing | applied | rejected | failed`
- `error_code`
- `error_message`
- `created_at`
- `updated_at`

## 5. 现有字段建议补充或调整

### 5.1 iOS 现有模型补充

建议新增 Swift 模型：

- `CoachProfile`
- `CoachPlan`
- `CoachPlanDay`
- `CoachPlanExercise`
- `CoachFeedbackDraft`
- `CoachAdjustmentResult`

建议新增 Service / ViewModel：

- `CoachServiceProtocol`
- `SupabaseCoachService`
- `CoachHomeViewModel`
- `CoachPlanDetailViewModel`
- `CoachAdjustmentViewModel`

### 5.2 messages.content_blocks 扩展

若计划调整仍走聊天入口，建议新增 block 类型：

- `coach_plan_summary`
- `coach_adjustment_summary`
- `coach_feedback_ack`

但注意：`content_blocks` 只用于展示层，不应作为计划主数据来源。计划主数据必须落在独立表中。

### 5.3 conversations.conversation_type 扩展

当前只有 `default` 语义。建议扩展：

- `default`
- `coach`
- `history_review`

这样可以把“训练日志聊天”和“教练对话”区分开。

## 6. API 契约草案

推荐新增独立 edge function，而不是把所有能力继续叠加到 `chat-send-message`。

### 6.1 生成计划

`POST /functions/v1/coach-generate-plan`

请求体：

```json
{
  "goal": "strength",
  "days_per_week": 4,
  "session_minutes": 75,
  "experience_level": "intermediate",
  "equipment_access": ["barbell", "bench", "dumbbell", "rack"],
  "injuries_limitations": [],
  "preferred_split": "upper_lower",
  "notes": "想优先提升卧推和深蹲",
  "timezone": "Asia/Shanghai",
  "preview_only": false
}
```

成功响应：

```json
{
  "plan_id": "uuid",
  "status": "active",
  "summary_text": "这是一个 4 天上/下肢力量计划。",
  "weeks": 4,
  "start_date": "2026-03-23",
  "end_date": "2026-04-19",
  "days": [
    {
      "plan_day_id": "uuid",
      "week_index": 1,
      "day_index": 1,
      "title": "上肢力量",
      "focus": "bench",
      "estimated_duration_minutes": 75,
      "exercises": [
        {
          "plan_exercise_id": "uuid",
          "exercise_name": "Bench Press",
          "normalized_name": "bench press",
          "target_sets": 5,
          "target_reps": 5,
          "target_weight": 80,
          "weight_unit": "kg",
          "target_rpe": 8,
          "rest_seconds": 180,
          "notes": "最后一组保留 1-2 次余力"
        }
      ]
    }
  ]
}
```

错误码建议：

- `400 INVALID_ARGUMENT`
- `401 UNAUTHORIZED`
- `409 ACTIVE_PLAN_EXISTS`
- `422 INSUFFICIENT_HISTORY`
- `500 PLAN_GENERATION_FAILED`

### 6.2 获取当前生效计划

`GET /functions/v1/coach-get-active-plan`

成功响应：

```json
{
  "plan_id": "uuid",
  "status": "active",
  "summary_text": "当前是第 2 周。",
  "current_week_index": 2,
  "days": []
}
```

错误码建议：

- `401 UNAUTHORIZED`
- `404 ACTIVE_PLAN_NOT_FOUND`

### 6.3 调整计划

`POST /functions/v1/coach-adjust-plan`

请求体：

```json
{
  "plan_id": "uuid",
  "request_text": "下周把深蹲重量降一点，最近膝盖有点不舒服",
  "source": "chat"
}
```

成功响应：

```json
{
  "adjustment_request_id": "uuid",
  "status": "applied",
  "summary_text": "已将下周下肢日的深蹲强度下调，并加入腿举替代选项。",
  "updated_plan_id": "uuid",
  "changes": [
    {
      "type": "modify_exercise",
      "week_index": 2,
      "day_index": 2,
      "exercise_name": "Back Squat"
    }
  ]
}
```

错误码建议：

- `400 INVALID_ARGUMENT`
- `401 UNAUTHORIZED`
- `404 PLAN_NOT_FOUND`
- `409 PLAN_NOT_ACTIVE`
- `422 ADJUSTMENT_NOT_UNDERSTOOD`
- `500 PLAN_ADJUSTMENT_FAILED`

### 6.4 提交训练反馈

`POST /functions/v1/coach-submit-feedback`

请求体：

```json
{
  "plan_id": "uuid",
  "plan_day_id": "uuid",
  "workout_session_id": "uuid",
  "completed": true,
  "difficulty_score": 4,
  "energy_score": 3,
  "pain_points": ["left_knee"],
  "freeform_feedback": "卧推状态不错，但深蹲底部有点卡。"
}
```

成功响应：

```json
{
  "feedback_event_id": "uuid",
  "status": "recorded",
  "next_action": "adjust_recommended",
  "message": "已记录，建议在下次下肢训练前调整计划。"
}
```

错误码建议：

- `400 INVALID_ARGUMENT`
- `401 UNAUTHORIZED`
- `404 PLAN_DAY_NOT_FOUND`
- `409 FEEDBACK_ALREADY_SUBMITTED`

## 7. 推荐的数据流

### 7.1 生成计划

1. iOS 采集教练资料和目标
2. iOS 调用 `coach-generate-plan`
3. edge function 聚合 `workout_sessions / exercise_prs / user_preferences / coach_profiles`
4. edge function 调 LLM 生成计划草案
5. edge function 写入 `coach_plans` 及子表
6. iOS 渲染计划页

### 7.2 调整计划

1. 用户通过聊天或表单输入调整意图
2. iOS 调用 `coach-adjust-plan`
3. edge function 解析意图并形成结构化 patch
4. edge function 产出新计划版本或更新当前计划
5. iOS 展示调整结果摘要

### 7.3 反馈回写

1. 用户完成一次训练
2. iOS 提交反馈和关联 `workout_session_id`
3. edge function 写入 `coach_feedback_events`
4. 后端标记是否建议重新生成或调整计划

## 8. 实施建议

### 8.1 第一期

目标：先把“计划生成”跑通，不做复杂自然语言调整。

建议范围：

- 新增 `coach_profiles`
- 新增 `coach_plans / coach_plan_days / coach_plan_exercises`
- 新增 `coach-generate-plan`
- iOS 新增只读计划页和重新生成入口

### 8.2 第二期

目标：支持简单结构化调整。

建议范围：

- 新增 `coach_adjustment_requests`
- 新增 `coach-adjust-plan`
- 支持固定几类调整：减量、换动作、增减频率、修改时长

### 8.3 第三期

目标：接入反馈闭环。

建议范围：

- 新增 `coach_feedback_events`
- 新增 `coach-submit-feedback`
- 将反馈纳入下一次生成和调整上下文

## 9. 本 issue 的改动范围判断

这次 `PEA-14` 的产出是架构与接口边界说明，不要求直接落功能。

结论：

- 当前执行这个 issue，`PeakLog` 需要新增文档。
- `peaklog-core` 不需要立即修改运行逻辑。
- 但后续开发“AI 教练”功能时，必须新增 Supabase edge function 与数据库表，不可能仅靠 iOS 端完成。

## 10. 后续开发任务拆分建议

建议直接拆成以下开发 issue：

1. 设计并落地 `coach_profiles / coach_plans / coach_plan_days / coach_plan_exercises` schema
2. 实现 `coach-generate-plan` edge function
3. iOS 新增 `CoachServiceProtocol` 与 `SupabaseCoachService`
4. iOS 新增教练首页与当前计划详情页
5. 设计并实现 `coach-adjust-plan` 的结构化 patch 协议
6. 支持聊天入口中的 `coach_plan_summary` / `coach_adjustment_summary` block
7. 设计并实现 `coach_feedback_events` 与 `coach-submit-feedback`
8. 增补端到端测试：计划生成、计划拉取、计划调整、反馈回写
