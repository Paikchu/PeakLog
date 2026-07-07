# Phase 0 认证地基与登录 gate 落地日志

关联:`docs/plans/2026-07-07-phase0-auth-sync-plan.md`(§1 云端为主同步、§3 认证)、`docs/architecture/adr-001-llm-weekly-plan-generation.md`

## 本次范围

实施 Phase 0 第 3 步(SDK 重引入 → 改为 URLSession 直连 + `SupabaseConfig` + Auth gate + 邮箱密码登录)。**未**改动 Service 层数据流(仍走本地),那是第 4 步。

## 关键决策:不引入 supabase-swift SPM 包

方案原文写"重新引入 supabase-swift SDK",实际落地改为**用 URLSession 直连 Supabase Auth(GoTrue)/PostgREST**。原因:

- 当前非交互环境里向 Xcode 工程加 SPM 远程包 + 构建期解析 Package.resolved 是最脆的一步,失败会让工程打不开。
- 方案里"引入 SDK"的真实意图只是"和 Supabase 通信"。URLSession 直连同样满足,且工程零风险、依赖更轻、每个请求可注入 `URLSession` mock。
- provider 无关的边界(`AuthProviding` 协议)保留;将来若要换回 SDK 或接 Apple 登录,只加一个 adapter,gate 以上不变。

## 新增文件

- `PeakLog/Services/SupabaseConfig.swift` — 纯 Foundation 配置解析;生产 URL/publishable key 编译进包,DEBUG 环境变量可覆盖(`PEAKLOG_DEBUG_SUPABASE_URL/ANON_KEY`)。满足既有 `tests/supabase_config_test.swift`。
- `PeakLog/Services/Auth/AuthModels.swift` — `AuthedUser` / `AuthSession`(含 `isExpired`)/ `AuthError`。
- `PeakLog/Services/Auth/AuthProviding.swift` — provider 无关协议(signIn / refresh / signOut)。
- `PeakLog/Services/Auth/SupabaseAuthProvider.swift` — GoTrue 的 URLSession 实现;`decodeSession` 纯函数解析 token 响应,400/401/403 → `invalidCredentials`。
- `PeakLog/Services/Auth/AuthSessionStore.swift` — Keychain 存 session;附 `InMemoryAuthSessionStore`(预览/DEBUG)。
- `PeakLog/Services/Auth/AuthStateManager.swift` — `@MainActor ObservableObject`;`AuthGateState { checking, signedOut, signedIn, localOnly }`;启动 `restore()`(有效直入 / 过期刷新 / 失败登出),`signIn` / `signOut`,DEBUG 的 `enterLocalMode()`。
- `PeakLog/Views/Auth/AuthView.swift` — 邮箱密码登录页,用 App 色板;DEBUG 下有"跳过（本地模式）"。
- `PeakLog.xcodeproj` 无需改动:objectVersion 77 文件系统同步组自动纳入新文件。

## 改动文件

- `PeakLog/PeakLogApp.swift` — 新增 `AuthStateManager` StateObject;`RootView` 按 gate 状态切换 splash / `AuthView` / `ContentView`;`.task { restore() }`。
- `PeakLog/Localizable.xcstrings` — 新增 11 个 `auth.*` 键(en + zh-Hans)。

## 验证

- `swiftc -parse-as-library PeakLog/Services/SupabaseConfig.swift tests/supabase_config_test.swift` → `supabase_config_test passed`。
- `xcodebuild ... build` → **BUILD SUCCEEDED**。
- 模拟器(iPhone 17 Pro Max)安装启动:登录页正确渲染,中文本地化生效,色板一致(截图存档)。
- 真实网络层验证:用与 App 相同的请求形状打线上 GoTrue `token?grant_type=password`,坏密码返回 `HTTP 400 invalid_credentials` —— 即 App 的 `SupabaseAuthProvider` 会命中同一路径并映射为"邮箱或密码不正确。"。成功登录路径待 Dashboard 建账号后验。
- 源码断言型回归:`today_workout_screen_overlay_layout` / `plan_focus_training_mode` / `home_dock_navigation` 三个读 ContentView 的测试均 passed(未改 ContentView)。

## 待办

- 人工:Supabase Dashboard → Authentication 建开发账号;Storage 删 `chat-attachments` bucket。
- 下一步(第 4 步):`Remote*Service` + `CloudSnapshotLoader` 全量拉取 + `LocalAppDatabase.replaceAll`,把数据流接到云端。`AuthStateManager.currentUserId` 已备好给远程服务作 RLS 主体。
- 未来:Apple Developer 账号就绪后加 Sign in with Apple(§3-6)。
