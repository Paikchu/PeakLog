# Apple 登录实施计划

## 基线与隔离

- 从远端 `main` 的 `2d68d70` 创建 `codex/apple-login` 独立 worktree。
- 保留主 checkout 的签名差异和 `.workbuddy/`，不带入功能分支。
- 基线为 iPhone 17 Pro Max / iOS 26.5 上 114 个 XCTest 通过。

## 客户端

- 新增 32 字节安全随机 nonce 与 SHA-256 hex 计算。
- `AuthProviding` 增加 Apple 凭证接口；邮箱接口限制为 DEBUG。
- `SupabaseAuthProvider` 调用 SDK `signInWithIdToken`，首次姓名以 best-effort 更新 Auth metadata。
- `AuthStateManager`负责忙碌状态、错误映射、取消静默和重复提交保护。
- `AuthView` 使用 `SignInWithAppleButton`，Release 不展示邮箱密码控件。

## 配置与文档

- 仅向 `PeakLog.entitlements` 增加 `com.apple.developer.applesignin = Default`。
- 更新认证架构、API 说明和回归矩阵；不增加后端迁移。

## 验证

- XCTest：nonce、Apple Token 请求、会话映射、姓名 metadata、metadata 降级、错误与重复提交。
- 静态契约：Release Apple 按钮、DEBUG 邮箱 seam、entitlement 和本地化边界。
- 完整 XCTest、后端 Node 测试、Debug 模拟器构建、Release 无签名构建。
- iPhone 17 Pro Max 验证浅色、深色和系统 Apple 授权入口。

## 发布与回滚

- 推送 `codex/apple-login` 并创建面向 `main` 的 Draft PR。
- Apple Developer 启用 `com.max.PeakLog` capability，刷新开发与 App Store profile。
- Supabase Apple Provider 使用 `com.max.PeakLog` Client ID并保持 nonce 校验。
- 回滚方式为 revert PR；本变更没有数据库回滚步骤。
