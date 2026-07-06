# PeakLog 接口文档（iOS <-> Supabase Edge Functions）

## 1. 通用说明

- Base URL: `https://<project-ref>.supabase.co/functions/v1`
- 鉴权：`Authorization: Bearer <access_token>`
- 必需 Header：`apikey: <supabase_anon_key>`
- Content-Type: `application/json`

---

## 2. `POST /ai-workout-action`

今日训练动作与计划调整入口，返回 JSON。

### 2.1 请求体

```json
{
  "text": "把深蹲后两组各加2.5kg",
  "targetDate": "2026-04-02"
}
```

- `text`：动作请求文本，必填
- `targetDate`：目标日期，选填，默认服务端当天

### 2.2 成功响应

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

- `status`：`completed` 或 `clarify`
- `reply`：给用户展示的自然语言回复
- `contentBlocks`：结构化结果块，可能包含 `weekly_plan`、`today_plan`、`workout_record`
- `requiresTodayRefresh`：是否需要刷新 Today 页
- `quickActions`：快捷动作按钮
- `exerciseInsights`：动作建议摘要

### 2.3 主要错误码

- `400`：请求参数校验失败
- `401`：未授权
- `500`：agent/tool 持久化失败

---

## 3. 工具输入 Schema

以下工具由 agent 调用并在 Edge 中持久化：

- `commit_workout`
- `commit_running_workout`
- `update_profile_goal`
- `create_or_refresh_weekly_plan`
- `adjust_current_or_next_week_plan`
- `log_planned_set_completion`

Schema 定义源：`backend/supabase/functions/_shared/schema.ts`

维护要求：

- 新增工具字段时，同步更新 `_shared/schema.ts`、`_shared/agent.ts` 和 `ai-workout-action/index.ts`
- iOS 侧只消费 Today 当前需要的领域数据，不保留聊天消息流
