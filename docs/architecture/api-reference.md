# PeakLog 接口文档（iOS <-> Supabase Edge Functions）

## 1. 通用说明

- Base URL: `https://<project-ref>.supabase.co/functions/v1`
- 鉴权：`Authorization: Bearer <access_token>`
- 必需 Header：`apikey: <supabase_anon_key>`
- Content-Type: `application/json`

---

## 2. `POST /chat-send-message`

聊天主入口，返回 SSE 流。

### 2.1 请求体

```json
{
  "conversation_id": "uuid",
  "text": "今天卧推 60kg 5x5",
  "client_message_id": "uuid-optional"
}
```

字段说明：

- `conversation_id`：会话 ID（必填）
- `text`：用户输入（必填）
- `client_message_id`：客户端幂等 ID（选填，建议传）

### 2.2 成功响应

- HTTP `200`
- `Content-Type: text/event-stream`
- 响应头：
  - `X-User-Message-Id`
  - `X-Assistant-Message-Id`

### 2.3 SSE 事件（核心）

常见事件类型（由 `ChatSSEParser` 解析）：

- `status`
  - `{"type":"status","phase":"processing|applying|completed|failed"}`
- `text-delta`
  - `{"type":"text-delta","textDelta":"..."}`
- `workout-block-stream-start`
  - `{"type":"workout-block-stream-start","toolCallId":"..."}`
- `workout-block-delta`
  - `{"type":"workout-block-delta","textDelta":"..."}`
- `workout-content-block`
  - `{"type":"workout-content-block","block":{...}}`
- `running-content-block`
  - `{"type":"running-content-block","block":{...}}`
- `plan-content-block`
  - `{"type":"plan-content-block","block":{...}}`
- `error`
  - `{"type":"error","message":"..."}`
- `done`
  - `{"type":"done"}`

### 2.4 主要错误码

- `400`：请求体无效 / 缺少必要参数
- `401`：缺少或无效 token
- `404`：conversation 不存在或不属于当前用户
- `500`：函数配置错误或内部处理失败

---

## 3. `POST /ai-workout-action`

今日训练动作与计划调整快捷入口，返回 JSON（非流式）。

### 3.1 请求体

```json
{
  "text": "把深蹲后两组各加2.5kg",
  "targetDate": "2026-04-02"
}
```

字段说明：

- `text`：动作请求文本（必填）
- `targetDate`：目标日期（选填，默认服务端当天）

### 3.2 成功响应

```json
{
  "status": "completed",
  "reply": "已帮你调整完成",
  "contentBlocks": [],
  "requiresTodayRefresh": true,
  "quickActions": [],
  "exerciseInsights": []
}
```

字段说明：

- `status`：`completed` 或 `clarify`
- `reply`：给用户展示的自然语言回复
- `contentBlocks`：结构化块（可能包含 `weekly_plan` / `today_plan` / `workout_record` 等）
- `requiresTodayRefresh`：是否需要刷新 Today 页
- `quickActions`：快捷动作按钮
- `exerciseInsights`：动作建议摘要

### 3.3 主要错误码

- `400`：请求参数校验失败
- `401`：未授权
- `500`：agent/tool 持久化失败

---

## 4. Content Blocks 契约（高频）

### 4.1 通用文本

```json
{ "type": "text", "text": "..." }
```

### 4.2 力量训练记录

```json
{
  "type": "workout_record",
  "workout_session_id": "uuid",
  "workout_date": "YYYY-MM-DD",
  "title": null,
  "parse_status": "completed",
  "exercises": [
    {
      "exercise_id": "uuid",
      "name": "Bench Press",
      "order_index": 0,
      "sets": [
        {
          "set_id": "uuid",
          "set_index": 1,
          "weight": 60,
          "weight_unit": "kg",
          "reps": 5
        }
      ]
    }
  ]
}
```

### 4.3 跑步记录

```json
{
  "type": "running_record",
  "running_workout_id": "uuid",
  "workout_date": "YYYY-MM-DD",
  "duration_minutes": 30,
  "distance_km": 5.2,
  "source": "chat"
}
```

### 4.4 周计划

- `type = weekly_plan`
- 包含：`plan_id`, `week_start_date`, `goal_summary`, `coach_summary`, `days[]`

### 4.5 今日计划

- `type = today_plan`
- 包含：`plan_id`, `goal_summary`, `day`

### 4.6 计划调整摘要

```json
{ "type": "plan_adjustment_summary", "summary_text": "..." }
```

### 4.7 PR 摘要

```json
{
  "type": "pr_summary",
  "summary_text": "本次刷新了2项PR",
  "items": []
}
```

---

## 5. 工具输入 Schema（服务端内部契约）

以下工具由 agent 调用并在 Edge 中持久化：

- `commit_workout`
- `commit_running_workout`
- `update_profile_goal`
- `create_or_refresh_weekly_plan`
- `adjust_current_or_next_week_plan`
- `log_planned_set_completion`

Schema 定义源：`backend/supabase/functions/chat-send-message/schema.ts`

维护要求：

- 新增工具字段时，需同步更新：
  - `schema.ts`（zod + parse 函数）
  - `chat-send-message/index.ts`（持久化逻辑）
  - iOS 模型解析与 UI 渲染

---

## 6. iOS 侧调用映射

- `SupabaseChatService.sendMessage(...)` -> `POST /chat-send-message`（SSE）
- `SupabaseWorkoutAIActionService.submitAction(...)` -> `POST /ai-workout-action`（JSON）
- 历史与计划列表由 Supabase 表查询获取（非 Edge）

---

## 7. 联调排障清单

- 先确认 token 是否有效（401 问题）
- 检查 `conversation_id` 是否归属当前用户（404 问题）
- 对 SSE 场景，确认 `Accept: text/event-stream` 已设置
- 若看到 failed 状态，检查 Edge 函数日志与工具输入是否匹配 schema
- 若 UI 无卡片，优先检查 `content_blocks` 实际落库内容
