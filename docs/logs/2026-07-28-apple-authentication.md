# Apple 登录交付记录

## 变更

- Release 登录页改为系统 Sign in with Apple。
- Supabase Swift SDK 2.53.0 负责 Apple ID Token 换取、会话持久化和 Auth 状态事件。
- Apple 首次授权姓名写入 Auth user metadata；失败时保留登录。
- DEBUG 本地模式与程序化邮箱云端检查保留。
- 主 App 增加 Apple 登录 entitlement；后端 Schema、RLS 和 Edge Function 无变更。

## 验证

- 基线：114 XCTest 通过，0 失败。
- 完整 XCTest：131 通过，0 失败；新增 17 个 Apple Auth 用例。
- 后端 Node 回归：100 通过，0 失败。
- `tests/apple_login_ui_contract_test.swift`、entitlement lint、xcstrings JSON 校验与 `git diff --check` 通过。
- Debug 构建、Release 无签名构建和 iPhone 17 Pro Max / iOS 26.5 安装启动通过。
- 浅色与深色登录页、Apple 按钮可访问性标签和系统授权入口通过模拟器验收。
- 主题切换时系统 Apple 按钮未重绘的问题通过 `colorScheme` identity 修复并复验。

## 外部状态

- 当前本机 provisioning profile 未包含 `com.apple.developer.applesignin`。
- Supabase 托管 Apple Provider 状态无法从仓库确认。
- 模拟器未登录 Apple Account，只验证到系统授权入口；未完成真实 Apple ID Token 交换。
- 未完成签名真实设备登录前，PR 保持 Draft。
