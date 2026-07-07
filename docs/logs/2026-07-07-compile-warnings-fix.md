# 修复三处 Swift 编译警告（2026-07-07，已实测验证）

## 背景
- 项目实际部署目标为 **iOS 26.2**（`IPHONEOS_DEPLOYMENT_TARGET = 26.2`），语言模式 `SWIFT_VERSION = 5.0` 但开启了严格并发检查（警告在 Swift 6 语言模式下即报错）。
- 在活动编译配置下出现三处编译警告，逐一修复且保持功能不变、修改最小化，并最终在模拟器上实测启动通过。

> 关键经验：**必须以安装 SDK 中 ActivityKit 的真实签名为准**，而非凭记忆。本机 SDK 为 iPhoneSimulator26.5，其 `Activity.end` 真正可用的非弃用签名是 `end(_ content: ActivityContent<ContentState>?, dismissalPolicy:)`（首参数无外部标签、类型为 `ActivityContent`，不是 `ContentState`）。

## 修复清单（最终正确版）

### 1. LiveActivityManager.swift（第 50、78 行）
- **问题**：`Activity.end(dismissalPolicy:)` 自 iOS 16.2 起被弃用。
- **第一版错误**：写成 `end(content: nil, dismissalPolicy: .immediate)`，结果报 `Extraneous argument label 'content:' in call` —— 因为新 API 的首参数**没有** `content:` 外部标签。
- **最终修复**：两处改为
  - `await existing.end(nil, dismissalPolicy: .immediate)`
  - `await activity.end(nil, dismissalPolicy: .immediate)`
- **原因**：非弃用签名为 `end(_ content: ActivityContent<ContentState>?, dismissalPolicy:)`；传 `nil` 表示结束时不更新活动内容，与原 `end(dismissalPolicy: .immediate)` 行为完全一致。

### 2. KeyboardDismissAction.swift（`defaultDismissHandler`）
- **问题**：`defaultDismissHandler()` 内部访问 `@MainActor` 隔离的 `UIApplication.shared`，被推断为 `@MainActor`；而它在非隔离 `init` 的默认参数 `Self.defaultDismissHandler` 中被引用，触发 “call to main actor-isolated static method in a synchronous nonisolated context”。
- **最终修复**：
  - 将函数标记为 `private nonisolated static func defaultDismissHandler()`；
  - 把 `UIApplication.shared.sendAction(...)` 包进 `MainActor.assumeIsolated { ... }`（其闭包是 `@MainActor`，访问合法；函数本身保持非隔离）；
  - 用 `_ = MainActor.assumeIsolated { ... }` 消费返回值，避免 “result of call to 'assumeIsolated' is unused” 新警告。
- **原因**：键盘收起总由主线程点击手势触发，`assumeIsolated` 保证在正确执行上下文；函数签名保持非隔离后，默认参数处的隔离冲突消除。

### 3. TodayWorkoutViewModel.swift（第 106 行 / init）
- **真正根因**：告警实际落在 designated `init` 的**默认参数** `liveActivityManager: PlanLiveActivityManaging = NoOpPlanLiveActivityManager()`。默认参数表达式在**非隔离上下文**中求值；而 `NoOpPlanLiveActivityManager` 因遵循 `@MainActor` 协议 `PlanLiveActivityManaging`，其编译器合成的 `init()` 被推断为 `@MainActor`，于是触发 “call to main actor-isolated initializer 'init()' in a synchronous nonisolated context”。
- **最终修复（两处，缺一不可）**：
  1. `NoOpPlanLiveActivityManager` 显式声明 `nonisolated init() {}`（该类无状态、无副作用，安全）。这消除默认参数处的隔离冲突。
  2. `TodayWorkoutScreen.swift` 的 `#Preview` 原本直接 `TodayWorkoutScreen(viewModel: TodayWorkoutViewModel())`；`#Preview` 闭包的 `body` 仅在 Swift 6 语言模式才是 `@MainActor`，本项目是 Swift 5 模式，故闭包为非隔离，直接调用 `@MainActor` 的 `TodayWorkoutViewModel()` 也会告警。改为用一个私有 `TodayWorkoutScreenPreview: View`，其 `body` 显式标注 `@MainActor`，在 `body` 内构造 ViewModel，预览闭包只构造非隔离的 `TodayWorkoutScreenPreview()`。
- **原因**：上述两处分别解决「默认参数非隔离求值」与「非隔离预览闭包构造 @MainActor 实例」两个独立触发点；行为不变。

## 影响范围
- 改动文件：`PeakLog/Services/LiveActivityManager.swift`、`PeakLog/Utilities/KeyboardDismissAction.swift`、`PeakLog/Views/Today/TodayWorkoutScreen.swift`。
- 未改动任何对外功能与运行时行为。
- 全仓已无 `end(dismissalPolicy:)` / `end(using:)` 调用。

## 实测验收
- `xcodebuild -scheme PeakLog -destination 'platform=iOS Simulator,id=BF450796-...' build`：**BUILD SUCCEEDED**，**全仓 0 警告**（含三处目标警告全部消失）。
- 安装并启动到已运行的 iPhone 17 Pro Max Simulator（iOS 26.5）：进程正常拉起（PID 运行、状态 0），**无崩溃日志**。

## 踩坑记录（供后续参考）
- SDK 真实 API 与“通用记忆”可能不一致，务必 `xcrun --sdk iphonesimulator --show-sdk-path` 后 grep `ActivityKit.swiftinterface` 核对 `end` 签名。
- “把 init 标成 nonisolated” 不是银弹：`TodayWorkoutViewModel` 是 `@MainActor final class`，其 init 体还引用 `@MainActor` 的 `AppServices` / `PlanLiveActivityManagerFactory.make()`，强行 `nonisolated` 会引出更多隔离告警；应按真实触发点（默认参数 / 非隔离调用方）精准修复。
