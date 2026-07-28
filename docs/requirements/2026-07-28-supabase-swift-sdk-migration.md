# Supabase Swift SDK 网络迁移需求

## 目标

- Auth、PostgREST 同步、`generate-weekly-plan` replan 全部通过 Supabase Swift SDK 2.53.0。
- 保留 local-first、push-first、revision guard、跨端保护、prune、append-only event 和 RLS 语义。
- 云请求在 token 不可用时 fail closed，不能退化为 publishable-key 匿名请求。

## 范围

- SDK 依赖、共享 Auth/API client、会话恢复、登录、退出、token 获取。
- `SupabaseDataClient` 现有方法边界内的 Database SDK 实现。
- `PlanReplanService` typed Functions SDK 实现。
- 迁移直接产生的旧 session、URLSession plumbing、测试和文档清理。

## 不做

- 不新增或部署 Schema、RLS、RPC、Storage、Edge Function。
- 不删除历史日志、已部署 migration 或旧聊天表。
- 不改变同步协调器的业务策略、客户端数据模型或计划生成契约。

## 会话行为

- SDK Keychain 固定使用 `com.max.PeakLog.auth` service 和 `current-session` key。
- 启动前删除不能解码为 SDK `Session` 的旧格式或损坏凭据；两名现有用户升级后需重新登录。
- 本地 session 先恢复 UI；网络 refresh 失败保持登录态。
- `validToken()` 在受保护请求或前台同步中收到 refresh 400、401、403 时清除本地 SDK session 并进入登录页；SDK 2.53 后台 auto-refresh 不暴露失败事件，因此不承诺后台 tick 当下关闭 UI gate。
- 退出固定使用 local scope。

## 验收

- 生产目录不再构造 Supabase `URLRequest`、Header、REST/Functions/Auth 路径或 refresh 请求。
- 13 张同步表读写、异构 optional 补 null、active-plan prune 和 append-only events 行为不变。
- Auth、Database、Functions 契约测试、完整 XCTest、backend tests、Release archive 通过。
- iPhone 17 Pro Max / iOS 26.5 完成登录、pull、push、prune、replan、离线重启和再次拉取。
- 线上相关表 RLS 保持开启，后端无迁移或函数版本漂移。
