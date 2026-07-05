# Supabase 后端恢复与 Apple ID 登录切换日志

- 已从 `/Users/max/Developer/IOS/PeakLog/backend` 恢复后端源码到当前项目 `backend/`。
- 未复制 `.env`、`.env.local`、Apple `.p8` 等 secret 文件。
- 已恢复 Supabase migrations、Storage 配置、`chat-send-message`、`ai-workout-action`、后端测试。
- 已将本地 Supabase 配置调整为关闭 email signup，开启 Apple provider 占位。
- 已修改 `handle_new_user()`，新用户展示名优先使用 Apple 首次授权带回的姓名 metadata，不再默认使用 email。
- 已补回训练 agent prompt 中的自重动作与短句补充记录约束。
- 已新增需求文档：`docs/requirements/2026-07-04-supabase-apple-auth-restore.md`。
- 已新增技术方案：`docs/plans/2026-07-04-supabase-apple-auth-restore-plan.md`。
- 已验证 `node --test backend/tests/*.test.mjs` 通过。
- 已创建新 Supabase 项目：`PeakLog` / `fqyurmsuvtdafbnynurg` / `ca-central-1`。
- 已绑定当前 `backend/supabase` 到新项目。
- 已推送 8 个 migrations 到新项目。
- 已写入 Edge Function secret：`DEEPSEEK_API_KEY`。
- 已部署 `chat-send-message` 和 `ai-workout-action`，状态均为 `ACTIVE`。
- 已验证无 token 调用 `chat-send-message` 返回 `401 Missing access token`。
- 已验证线上 public tables 为 20 个，`avatars` 和 `chat-attachments` bucket 存在。
- 待完成：Supabase Dashboard 开启 Apple provider、关闭 hosted Email signup；Apple Developer 中给 `com.max.PeakLog` 开启 Sign in with Apple。
