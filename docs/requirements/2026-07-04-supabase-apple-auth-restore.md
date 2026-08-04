# Supabase 后端恢复与 Apple ID 登录切换需求

- 恢复 PeakLog 原 Supabase 后端能力，沿用旧的 Postgres schema、RLS、Storage、Realtime、Edge Functions。
- 线上目标项目应为旧 iOS 配置中的 `dejoqutbflrrscgsvbog`；当前 Supabase 凭据无法访问该项目，Dashboard/MCP 返回 `Project not found`。
- App 登录方式只保留 Apple ID；移除邮箱、密码、注册、调试自动邮箱登录入口。
- Supabase Auth 关闭 email signup；Apple provider 开启，并保留 nonce 校验。
- iOS 使用 Apple 原生 `AuthenticationServices` 获取 `identityToken`，再交给 Supabase Auth 建立 session。
- 首次 Apple 授权返回的姓名写入 Supabase user metadata，避免 `profiles.display_name` 落成私密中继邮箱。
- 原业务数据继续按 `auth.users.id` 隔离；Apple 登录后的用户 UUID 作为所有 `user_id` 关联源。
- Edge Functions 继续负责聊天、训练记录解析、计划调整、PR 摘要生成。

## 验收

- Supabase 项目可见，且 ref 与 App 配置一致。
- `supabase db push --dry-run` 能列出待应用 migrations，正式 push 后 schema、trigger、storage bucket 存在。
- `chat-send-message` 与 `ai-workout-action` 两个 Edge Functions 部署成功。
- 线上 secret 存在 `DEEPSEEK_API_KEY`，函数健康检查不再返回缺失环境变量。
- Supabase Auth provider 中 Apple enabled，Email signup disabled。
- iOS 模拟器显示 Apple 登录按钮，不再出现邮箱/密码表单。
- Apple 登录成功后进入首页，`profiles`、`user_preferences`、`user_stats`、默认 `conversations` 自动创建。
- 发送一条训练聊天消息后，消息落库、assistant 回复、训练记录或计划内容能在 App 内显示。

## 2026-08-04 修订

「只保留 Apple ID 登录」（正文第 3 条）与「不再出现邮箱/密码表单」（验收第 6 条）已被 PR #159 推翻：邮箱密码表单重新出现在 Release 登录页，与 Apple 按钮并存，`AuthProviding.signIn(email:password:)` 不再是 `#if DEBUG`。原文保留，作为 2026-07-04 当时验收口径的记录；当前形状以 `docs/architecture/system-architecture.md` 与 `tests/apple_login_ui_contract_test.swift` 为准。

注意：本文档「Supabase Auth 关闭 email signup」一条**未**随之推翻。若该配置仍然生效，新用户无法通过这个表单注册，登录页也没有注册/找回密码入口。
