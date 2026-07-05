# Plan Live Workout

- Plan 页右下角加号改回上一版手动输入，打开 `DailyRecordSheet`。
- 手动输入继续支持力量、自重、有氧记录。
- 新增 `PeakLogLiveActivityExtension`，Live Activity 显示当前动作和“完成动作”按钮。
- 新增 `PlanLiveActivityAttributes`、`LiveActivityManager`、App Group entitlements 和 `NSSupportsLiveActivities`。
- 训练执行卡片改为 Liquid Glass 面板，文案收敛为正在训练、完成本组、保存、取消本次训练。
- 列表对勾和 Live Activity 按钮完成的 set id 合并，Confirm 跳过已落库组。
- 去掉 Plan 页可见的 AI 叙述，首页标题改为 PeakLog，记录区文案改为可编辑状态。
- 本次追加：移除自由文本 `PlanComposerSheet` 入口，空态文案恢复为手动记录。
- 验证：`swift tests/today_workout_screen_overlay_layout_test.swift` 通过。
- 验证：`xcodebuild -project /Users/max/Developer/PeakLog/PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,id=8AB8FBD4-8664-4A06-B763-DDB33DBC0DB9' -only-testing:PeakLogTests/TodayWorkoutLiveSessionTests test CODE_SIGNING_ALLOWED=NO` 通过。
- 验证：iOS 26.4 iPhone 17 Pro Max build/install/launch 通过，截图 `/tmp/peaklog-plan-liquid-live-updated.png` 非空。

## 2026-07-05 追加：手动计划 + 训练执行全屏页

- 右下角加号改为菜单：「添加训练计划」（新 `AddPlanExerciseSheet`，纯手动：动作名/负重类型/目标重量/次数/组数）+「手动记录」（原 `DailyRecordSheet`）。
- `LocalAppDatabase.addPlannedExercise` 支持在今日 plan 不存在或为 Rest（0 组）时新建/转化 plan day，否则追加到现有 exercises；`TrainingPlanServiceProtocol` 同步新增该方法。
- `TodayWorkoutViewModel` 新增 `addPlanExercise(...)`（写入后直接替换 `todayPlan`）与 `toggleLiveSet(setId:)`（任意组乱序切换完成状态，供全屏页使用；沿用原 cursor 逻辑供 Live Activity 展示"下一个未完成动作"）。
- 新增 `TrainingSessionScreen`：点击「开始训练」以 `fullScreenCover` 呈现，展示今日计划的全部动作和全部组，每组右侧一个对勾可随时切换完成状态，顶部进度、底部「结束并保存」「取消本次训练」。
- 移除原先内嵌在 Today 页、只展示当前一组的 `planLiveActivityCard`/`planLiveActivityContent`；抽出 `PlanProgressBar` 共享组件，`glassPanel`/`glassChip`/`glassActionBackground` 由 `private extension` 改为 `extension` 供新页面复用。
- Rest（0 组）时不再展示「开始训练」按钮。
- 新增本地化字符串（`today.plan.manual_day_title`、`today.add_menu.*`、`add_plan_exercise.*`、`training_session.*`）。
- 更新 `tests/today_workout_screen_overlay_layout_test.swift`：断言加号菜单同时暴露 `today.addDailyRecord` 与 `today.addPlanExercise`，且源码包含 `TrainingSessionScreen`、`toggleLiveSet`、`addPlanExercise`。
- 同步补齐 `TrainingPlanServiceProtocol` 新方法的现有 mock 实现（`PeakLogTests/TodayWorkoutLiveSessionTests.swift`、`tests/today_running_coexistence_test.swift`）。
- 验证：`xcodebuild ... -scheme PeakLog build`（含 `PeakLogLiveActivityExtension`）通过；`xcodebuild ... test`（`PeakLogTests` 全量）通过；`swift tests/today_workout_screen_overlay_layout_test.swift` 通过；iPhone 17 Pro Max 模拟器 install/launch 通过，截图确认首页渲染无回归。
- 未完成验证项：本沙箱环境缺少 Accessibility 权限（`osascript`/`CGEvent` 触发点击均返回 -25204），且项目暂无 XCUITest target，无法在本次会话中做「加号 → 添加计划 → 开始训练 → 勾选 → 结束保存」的真实点击链路回归，需要用户在真机/本机 Xcode 环境手动点击验证一遍。

## 2026-07-05 追加：修复 Live Activity “完成动作”点不动 / Xcode SpringBoard 报错

- 根因：项目此前没有任何已提交的 `.xcscheme`（`xcuserdata/.../xcschememanagement.plist` 里的两个 scheme 都标着 `_^#shared#^_` 但磁盘上并不存在对应文件），Xcode/`xcodebuild -list` 因此临时“隐式生成”了 `PeakLog` 和 `PeakLogLiveActivityExtension` 两个 scheme。隐式生成的 Widget Extension scheme 默认 Run 目标是 “Ask on Launch”，选择宿主时如果选到 SpringBoard/Home Screen 直接跑该 scheme，会走 Xcode 一个已知不稳定的路径——`com.apple.dt.deviceprocesscontrolservice` 请求 SpringBoard 单独展示这个 Widget，且概率性报错 `FBSOpenApplicationServiceErrorDomain Code=1 RequestDenied`；用这种方式启动时并没有真正跑 `PeakLog` App、也没有调用 `LiveActivityManager.start()` 走 `Activity.request(...)`，所以看到的卡片不是一个由 App 正常驱动的 Activity，点“完成动作”自然没有真实状态可以推进。
- 交叉验证：`~/Library/Logs/DiagnosticReports` 里 6 份 `ExcUserFault_PeakLogLiveActivityExtension` crash（`EXC_GUARD`/`_XPC_MISUSE_FAULT`，堆栈全部是系统 XPC/BaseBoard 框架，没有任何 App 代码）+ `log show` 里 `IDELaunchReport ... PeakLog:PeakLogLiveActivityExtension:Run:...: Launch com.apple.springboard` 这一行，确认了用户是在直接跑 `PeakLogLiveActivityExtension` scheme、宿主选到了 SpringBoard。
- 修复：新增两个共享 scheme 文件 `PeakLog.xcodeproj/xcshareddata/xcschemes/PeakLog.xcscheme` 和 `.../PeakLogLiveActivityExtension.xcscheme`；后者的 `LaunchAction`/`ProfileAction` 的 `BuildableProductRunnable` 直接指向 `PeakLog.app`（而不是 Ask on Launch/SpringBoard），这样即使以后误选了 Widget Extension 的 scheme 去 Run/Debug，Xcode 也会先正常启动 `PeakLog` App（真正调用 `Activity.request` 创建 Live Activity），再把调试器 attach 到随之启动的 Widget Extension 进程上，不再请求 SpringBoard 单独展示 Widget。
- 正确的验证方式：选择 **`PeakLog`** scheme（不是 `PeakLogLiveActivityExtension`）Run，在 App 内走「开始训练」进入执行态，Live Activity 出现在锁屏/灵动岛后点“完成动作”。
- 验证：新增 shared scheme 后 `xcodebuild -scheme PeakLog build`、`xcodebuild -scheme PeakLogLiveActivityExtension build` 均通过；`xcodebuild -scheme PeakLog test`（`PeakLogTests` 全量）在独立模拟器（8AB8FBD4，避免和用户本机正在跑的 BF450796 抢占）上通过；`xcrun simctl erase` 后 BF450796 无新增 crash report。
