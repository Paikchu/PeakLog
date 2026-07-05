# Supabase 后端恢复与 Apple ID 登录切换计划

## 已确认

- 新 Supabase 项目已创建：`PeakLog` / `fqyurmsuvtdafbnynurg` / `ca-central-1`。
- 新项目 URL：`https://fqyurmsuvtdafbnynurg.supabase.co`。
- 新项目 publishable key：`sb_publishable_7UeChilW6B8aPscPF9huzg_tXniKGal`。
- 当前工作区 `/Users/max/Developer/PeakLog` 没有 `backend/`，也不是 git 仓库。
- 旧后端仍在 `/Users/max/Developer/IOS/PeakLog/backend/supabase`，包含 8 个 migrations、2 个 Edge Functions、测试和 `.env.local`。
- 旧 iOS 线上 Supabase ref 是 `dejoqutbflrrscgsvbog`，publishable key 仍在旧 `PeakLog/Supabase/Config.swift`。
- 当前 Supabase token 只能看到 `Conviction Log` 项目 `qfzidyvgtfygetveyzml`；旧 ref 查询失败。
- Supabase 文档建议 iOS/macOS 使用原生 Apple 登录，再通过 ID token 建 Supabase session；OAuth secret 6 个月轮换只影响 Web/OAuth 流，不影响纯原生路径。
- Changelog 中与本次相关的风险：新表可能不再自动暴露到 Data API；Edge Functions 运行时已是 Deno 2.1；旧 anon OpenAPI 访问被移除。

## 阻塞点

- Apple 登录需要 Apple Developer 配置：Bundle ID `com.max.PeakLog` 开启 Sign in with Apple。
- Hosted Supabase Auth provider 仍需在 Dashboard 中开启 Apple，并关闭 Email signup；本地 `config.toml` 已改，但 `db push` 不会同步 Auth provider 设置。

## 技术方案

- 后端恢复
  - 将旧 `/Users/max/Developer/IOS/PeakLog/backend` 恢复到当前 `/Users/max/Developer/PeakLog/backend`。
  - 执行 `supabase link --project-ref <peaklog-ref>` 绑定项目；当前 CLI `db push` 不支持直接传 `--project-ref`。
  - 保留旧 migrations 顺序，先执行 `supabase db push --dry-run`。
  - 正式执行 `supabase db push --include-all`，再部署 `chat-send-message`、`ai-workout-action`。
  - 使用 `supabase secrets set --env-file .env.local --project-ref <peaklog-ref>` 写入 `DEEPSEEK_API_KEY`。

- Auth 配置
  - Supabase Dashboard 或 Management API 开启 Apple provider。
  - 关闭 Email signup；不删除历史 email 用户，避免误伤旧数据。
  - 本地 `supabase/config.toml` 同步为 `[auth.email].enable_signup = false`、`[auth.external.apple].enabled = true`。
  - 修改 `handle_new_user()`：`display_name` 优先 `full_name` / `given_name`，最后才用 email。

- iOS 恢复
  - 从旧 iOS 代码恢复 `Supabase/`、`Supabase*Service`、`ConversationService`、`AuthStateManager` 相关运行链路。
  - 给 target 增加 Sign in with Apple capability 和 entitlement。
  - 用 `SignInWithAppleButton` 替换 `AuthView` 邮箱表单。
  - 生成 raw nonce 与 SHA-256 nonce；Apple request 用 hashed nonce，Supabase `signInWithIdToken` 用 raw nonce。
  - 首次登录拿到 `fullName` 后调用 `supabase.auth.update(user:)` 或 SDK 等价 API 写入 metadata。

- 安全修正
  - 将关键 RLS 的 `FOR ALL USING` 补齐 `WITH CHECK`，避免客户端写入跨用户 `user_id`。
  - Edge Functions 目前 `verify_jwt = false`，但函数内部校验 `Authorization` access token；部署后用无 token 请求验证 401。
  - 不把 `service_role`、DeepSeek key、Apple key 写入 App 或仓库。

## 验收命令

```bash
cd /Users/max/Developer/PeakLog/backend
supabase link --project-ref fqyurmsuvtdafbnynurg
supabase db push --dry-run
supabase secrets list --project-ref fqyurmsuvtdafbnynurg
supabase functions deploy chat-send-message --project-ref fqyurmsuvtdafbnynurg --use-api --no-verify-jwt
supabase functions deploy ai-workout-action --project-ref fqyurmsuvtdafbnynurg --use-api --no-verify-jwt
```

```bash
xcodebuild -project /Users/max/Developer/PeakLog/PeakLog.xcodeproj \
  -scheme PeakLog \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4' \
  build
```
