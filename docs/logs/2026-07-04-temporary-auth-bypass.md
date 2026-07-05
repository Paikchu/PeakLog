# 临时跳过登录验收日志

- 当前 `/Users/max/Developer/PeakLog` 已处于跳过登录状态。
- `PeakLogApp` 直接加载 `ContentView()`，没有 `AuthView`、`AuthStateManager` 或 Supabase Auth gate。
- `rg` 检查 `PeakLog/*.swift`，未发现登录入口或认证状态拦截。
- 已用 iPhone 17 Pro Max Simulator 目标构建通过。
- 验证命令：`xcodebuild -project /Users/max/Developer/PeakLog/PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /Users/max/Developer/PeakLog/build CODE_SIGNING_ALLOWED=NO build`。
- 结果：`BUILD SUCCEEDED`。
- 后续接回 Apple ID 登录时，需要重新引入 Auth gate，并确保未登录用户只被拦到登录页。
