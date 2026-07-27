# Supabase Swift SDK 网络迁移交付记录

## 变更

- `supabase-swift` 精确锁定 2.53.0，App target 链接 `Supabase`，提交 `Package.resolved`。
- `SupabaseConfig` 统一为 `publishableKey`；Auth/API client 分别使用 30/60 秒 session。
- Auth 改为 SDK session、状态事件、自动刷新和 local sign-out；旧 session 格式升级时清除。
- Database 改为 SDK select/filter/order/limit、upsert/update/delete/notIn；Functions 改为 typed invoke。
- Database/Functions 请求保留 `validToken()` fail-closed 门；已验证 token 通过 relay 提供给 SDK，SDK 发送阶段不再二次调用可能失败的 token provider，也不会退化为匿名请求。
- SDK 后台 auto-refresh 不暴露失败事件；受保护请求或 foreground sync 首次确认 refresh 400/401/403 时 local sign-out，网络失败保留 session。
- 保留 local-first、push-first、revision guard、append-only events 与 active-plan scoped prune。

## 清理

- 删除自管 `AuthSession`/Keychain store、对应测试和三个失效网络 swiftc harness。
- bulk-null、token failure、push-first 迁入 `PeakLogTests`。
- 删除已跟踪 `xcuserdata`，并在 `.gitignore` 屏蔽。
- 历史日志与已部署 migration 未改写；旧聊天表未纳入本次下线。

## 验证

- SDK 依赖解析：2.53.0。
- Auth targeted XCTest：新增存储边界后 9 passed；Auth/AuthStateManager 合计 16 passed。
- Database/Functions/push-first targeted XCTest：19 passed。
- 完整 XCTest：113 passed，0 failed，0 skipped。
- 独立 Swift 回归：Supabase 配置、前台 Auth gate、pull merge、push-first 持久化、append-only edit event、profile defaults 全部通过。
- backend Node：100 passed。
- 无签名 Release archive：`ARCHIVE SUCCEEDED`。
- iPhone 17 Pro Max / iOS 26.5：构建、安装、启动通过；无可用 Tester 凭据，真实登录与云端写入/清理未执行。
- TestFlight 冒烟未执行；真实账号 E2E 与 TestFlight 仍是 PR 从 draft 转为可合并的硬门槛。

## 后端影响

- 未新增或部署 migration、RLS、RPC、Storage、Edge Function。
- `backend/supabase` 相对基线零 diff。
- 线上 13 张同步表 RLS 全部开启；`generate-weekly-plan` version 9 为 `ACTIVE` 且 `verify_jwt=true`。
- 线上历史 migration 版本命名与仓库已有文件名存在既存差异；本次未修改或尝试对齐。
