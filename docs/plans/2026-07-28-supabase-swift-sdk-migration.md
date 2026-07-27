# Supabase Swift SDK 网络迁移开发计划

## 基线与交付

- 基线：`origin/main@7ec5a32fa030ae7cb83ac160f49e95fb55059a1c`。
- 分支：`codex/migrate-supabase-swift-sdk`，独立 worktree，单 PR。
- 四个 commit：依赖/组合根、Auth、Database/Functions、清理/文档。
- main 不接收中间态；任一验收门失败时 PR 不合并。

## 依赖与组合根

- App target 精确依赖 `supabase-swift` 2.53.0，提交 `Package.resolved`；Live Activity target 不链接。
- `SupabaseConfig` 只保留 `url`、`publishableKey` 及同名 debug override。
- Auth client：30 秒 ephemeral session、SDK Keychain、自动 refresh、local initial session。
- API client：60 秒 session、Auth provider token closure；生产 PostgREST retry 开启，测试关闭。

## Auth

- `SupabaseAuthProvider` 包装 SDK Auth，输出用户恢复/状态事件、邮箱密码登录、local sign-out、valid token。
- `AuthStateManager` 只保留 UI gate、重复提交、状态绑定和错误文案。
- 删除自管 session、refresh task、Keychain 编解码与写入。
- 用可注入 SDK adapter seam 覆盖离线恢复、refresh 拒绝、网络失败、local sign-out、双击登录和 SDK single-flight。

## Database 与 Functions

- `SupabaseDataClient` 保留 fetch/upsert/update/deleteNotIn/insertIgnoringDuplicates 边界。
- query item 映射为 SDK select/filter/order/limit；写入使用 minimal returning。
- 批量 Encodable 转成 `[[String: AnyJSON]]`，按键并集补 `.null`。
- 所有 Database/Functions 调用先执行 `validToken()`。
- SDK 错误映射为 `notConfigured/network/unauthorized/remote(code,message)`。
- `PlanReplanService` typed invoke 保持 `replanned/noChange/failed`。

## 清理

- 删除 `AuthSession`、session store、Keychain 自研测试和旧 URLSession adapter 测试。
- 删除失效 swiftc 网络测试；将 bulk-null、push-first、token failure 迁入 XCTest。
- 删除已跟踪 `xcuserdata`，忽略整个 `xcuserdata`。
- 更新架构、回归矩阵和交付日志；历史日志不改写。

## 验证

- 每阶段先跑新增失败测试，再实现并跑 targeted tests。
- 最终执行 package resolve、完整 XCTest、可用的纯逻辑 tests、backend Node tests、无签名 Release archive。
- 模拟器固定 iPhone 17 Pro Max / iOS 26.5，禁止并行 test host。
- 使用 Tester 账号验证真实往返；凭据缺失时记录阻塞，PR 保持 draft。
- 检查 13 张相关表 RLS、远端 migration/function 漂移和全仓旧符号。
