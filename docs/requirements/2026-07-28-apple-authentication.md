# Apple 登录需求

## 目标

- Release 登录页只提供原生 Sign in with Apple。
- Apple ID Token 由 Supabase Swift SDK 换取并持久化 Supabase 会话。
- DEBUG 保留本地模式与云端 E2E 使用的程序化邮箱登录。

## 用户流程

- 登录页展示系统 Apple 登录按钮，请求姓名与邮箱。
- App 为每次授权生成独立 raw nonce，Apple 请求使用 SHA-256 nonce，Supabase 校验使用原始 nonce。
- 授权成功后进入现有登录态与云同步流程。
- 用户取消 Apple 授权时停留在登录页，不显示错误。
- 授权、Token 或网络失败时停留在登录页并显示可重试错误；授权和网络请求期间禁止重复提交。

## 数据与权限

- Apple 首次返回姓名时写入 `auth.users.user_metadata` 的 `full_name`、`given_name`、`family_name`。
- 姓名 metadata 更新失败不撤销已建立的登录会话。
- 不写 `profiles`，不新增 Schema、RLS、RPC 或 Edge Function。
- 主 App 增加 Sign in with Apple entitlement；Live Activity Extension 不增加该权限。

## 不做

- 不保留 Release 邮箱密码入口。
- 不实现 Web OAuth、Services ID、回调 URL或 `.p8` secret 轮换。
- 不改变账号合并、删除账号或资料昵称规则。

## 验收

- Release 源码与登录页没有邮箱密码入口。
- Apple Token 请求包含 provider、ID Token 与对应 raw nonce。
- 登录、取消、错误和重复提交均有自动化覆盖。
- iOS 26.5 iPhone 17 Pro Max 模拟器构建、测试和登录页验收通过。
- Apple Developer 与 Supabase 托管配置不可用时，PR 保持 Draft 并记录真实设备验证缺口。
