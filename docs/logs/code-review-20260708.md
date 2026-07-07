# PeakLog 代码审查报告（Code Review）

- **审查日期**：2026-07-08
- **审查范围**：`PeakLog/`（66 个 Swift 文件）+ `PeakLogShared/`（2 个 Swift 文件），不含测试
- **审查维度**：① 多余代码 ② 逻辑 Bug ③ 安全问题 ④ 边界异常（Corner Case）⑤ 优化建议
- **审查方式**：分层（数据层 / 服务·鉴权层 / UI·视图层）并行静态审查

---

## 一、总览汇总表

### 按问题类型与严重级别分布

| 问题类型 | 高 (High) | 中 (Medium) | 低 (Low) | 小计 |
|---|---:|---:|---:|---:|
| ① 多余代码 | 0 | 0 | 14 | 14 |
| ② 逻辑 Bug | 3 | 9 | 3 | 15 |
| ③ 安全问题 | 0 | 0 | 7 | 7 |
| ④ 边界异常 | 0 | 4 | 8 | 12 |
| ⑤ 优化建议 | 0 | 5 | 18 | 23 |
| **合计** | **3** | **18** | **50** | **71** |

### 按模块分布

| 模块 | High | Medium | Low |
|---|---:|---:|---:|
| 数据 / 持久层 | 2 | 4 | 11 |
| 服务 / 鉴权 / 云同步层 | 1 | 8 | 10 |
| UI / 视图 / ViewModel 层 | 0 | 6 | 19 |
| **合计** | **3** | **18** | **50** |

### 优先修复清单（Top 5，影响数据正确性或用户数据安全）

1. 🔴 `LocalAppDatabase` 体积统计忽略重量单位（lbs 当 kg 累加）
2. 🔴 `CloudSyncCoordinator.pull()` 登录后无条件覆盖本地 → 离线/DEBUG 记录丢失
3. 🔴 `AuthStateManager.validToken()` 刷新竞态 → 偶发强制登出
4. 🟠 PR 跨单位比较错误（kg 与 lbs 混用）
5. 🟠 `LiveActivityManager` 非 `@MainActor` + 大计划 payload 超 4KB 静默失败

---

## 二、② 逻辑 Bug（含全部 High）

### 🔴 [High] 总训练容量忽略重量单位，lbs 被当 kg 累加
- **位置**：`PeakLog/Services/LocalAppDatabase.swift:690-694`（`LocalAppDatabasePreviewDriver` 约 1018-1022 同构）
- **问题**：`recalculateDerivedProfile` 累加 `totalVolume` 时直接 `set.weight * Double(set.reps)`，未对 `weightUnit` 做归一化；结果存入 `totalVolumeKg`，而 `ProfileViewModel.volumeDisplay` 当 kg 显示且无任何换算。用 lbs 记录的用户数值与单位标签全部错误（如 100 lbs×10 显示成 "1t"）。
- **修复**：累加前归一化到 kg。
  ```swift
  let factor: Double = (set.weightUnit == .lbs) ? 0.453592 : 1.0
  subtotal + ((set.weight ?? 0) * factor * Double(set.reps))
  ```

### 🔴 [High] 登录后 `pull()` 整体覆盖本地数据，导致本地记录丢失
- **位置**：`PeakLog/Services/Cloud/CloudSyncCoordinator.swift:46-49, 67-81`
- **问题**：`start()` 直接 `pull()` 后 `database.replaceAll(...)`，无任何本地→云端合并。用户在 DEBUG/local/离线模式下创建的训练记录，一旦登录即被云端快照整体替换而丢失（注释称"为避免推送 seed 行"的有意设计，但牺牲了本地数据安全）。
- **修复**：`start()` 前做三路合并（以 `updatedAt` 较新者为准），或登录前先将本地未同步记录并入推送包再 `replaceAll`。

### 🔴 [High] `validToken()` 刷新竞态导致会话被误清空、强制登出
- **位置**：`PeakLog/Services/Auth/AuthStateManager.swift:85-99`
- **问题**：`validToken` 为 `@MainActor`，但 `await provider.refresh(...)` 挂起时释放主 Actor。多个后台同步任务并发调用且会话过期时，会**并发发出两次 refresh**（共用同一 `refreshToken`）。Supabase 开启 refresh-token rotation，第二次用已被吊销的 token 刷新返回 401 → 触发 catch 块 `store.clear(); session = nil` → 把第一个调用刚写入的有效会话清空。
- **修复**：single-flight 串行化刷新；仅在刷新失败且本会话未被新会话取代时才清空：
  ```swift
  private var refreshTask: Task<AuthSession, Error>?
  func validToken(now: Date = Date()) async throws -> String {
      guard let current = session else { throw AuthError.invalidCredentials }
      if !current.isExpired(now: now) { return current.accessToken }
      let task = refreshTask ?? Task { [provider] in
          try await provider.refresh(refreshToken: current.refreshToken) }
      refreshTask = task
      do {
          let refreshed = try await task.value
          refreshTask = nil
          persist(refreshed)
          return refreshed.accessToken
      } catch {
          refreshTask = nil
          if session?.accessToken == current.accessToken {
              store.clear(); session = nil; state = .signedOut
          }
          throw AuthError.invalidCredentials
      }
  }
  ```

### 🟠 [Medium] PR 比较无视重量单位
- **位置**：`PeakLog/Services/LocalAppDatabase.swift:700-718`；`ProfileViewModel.swift:99-103`
- **问题**：`max(by:)` 只比原始数值，同一动作混用 kg/lbs（如 100 kg vs 225 lbs）会被错误判定；ViewModel 再次按原始 `maxWeight` 排序放大错误。
- **修复**：比较前统一换算到 kg，或 `ExercisePR` 额外保存 `maxWeightKg` 用于排序。

### 🟠 [Medium] `ProfileViewModel.volumeDisplay` 单位固定且取整错误
- **位置**：`PeakLog/ViewModels/ProfileViewModel.swift:88-95`
- **问题**：无论用户 `weightUnit` 是 lb 还是 kg，都固定输出 `"kg"/"t"`；`kg/1000` 后用 `%.0f`，1500kg（1.5t）会显示成 `"2t"`。
- **修复**：尊重用户单位并正确取整（见前文示例）。

### 🟠 [Medium] `PreferenceToggleRow` Binding 丢弃新值，开关不立即翻转
- **位置**：`PeakLog/Views/Profile/ProfileScreen.swift:270-278, 284-295`
- **问题**：`set: { _ in Task { ... } }` 丢弃了 SwiftUI 提出的 `!value`，body 重算时 `get` 仍返回旧值 → 开关不翻转、保存期间闪烁；深色模式那条乐观更新了 `themeManager` 但与 `profile.preferences` 可能不一致（保存失败时主题已变、profile 未变）。
- **修复**：用本地 `@State` 做乐观镜像，或让 ViewModel 暴露可写真值 Binding。

### 🟠 [Medium] `HistoryPlanDaySection` 硬编码 "Today" 且 fallback 展示原始日期串
- **位置**：`PeakLog/Views/History/HistoryPlanDaySection.swift:8`
- **问题**：`day.planDate == WorkoutDateFormatter().string(from: Date())` 比较的是设备当前日期串；fallback 直接展示 `yyyy-MM-dd` 原始字符串，未本地化、不可读。
- **修复**：比较"本地当天日期"，fallback 用本地化日期格式。

### 🟠 [Medium] `HomeDockBar.HomeTab.title` 返回硬编码英文，无障碍标签恒为英文
- **位置**：`PeakLog/Views/Home/HomeDockBar.swift:10-19, :102`
- **问题**：非英语环境下 `accessibilityLabel` 永远是英文。
- **修复**：改用 `LocalizedStringKey` 或本地化 lookup。

### 🟠 [Medium] `TodayWorkoutScreen.onAppear` 守卫导致陈旧数据不刷新
- **位置**：`PeakLog/Views/Today/TodayWorkoutScreen.swift:178`
- **问题**：`onAppear()` 守卫 `guard todayPlan == nil, todayRecord == nil, runningRecords.isEmpty else { return }`。切走再切回不刷新；若"部分加载"（只有 plan、record 为 nil）守卫失败而永不刷新。
- **修复**：改为始终 `refresh()`，或至少 `.refreshable` + 切回时刷新。

### 🟡 [Low] `CloudMapper` `duration_seconds / 60` 整数截断
- **位置**：`PeakLog/Services/Cloud/CloudMapper.swift:333`（30 秒会丢成 0 分钟）
- **修复**：`Int(round(Double($0) / 60))` 或云端存分钟精度。

### 🟡 [Low] `ExerciseSet.reps` 可选拉回静默变 0
- **位置**：`PeakLog/Services/Cloud/CloudMapper.swift:316`
- **修复**：`reps == nil` 视为脏数据跳过/报错，而非 `?? 0`。

---

## 三、③ 安全问题（均为 Low，无严重泄露）

### 🟡 [Low] Supabase anon key 硬编码进源码 + URL 强制解包
- **位置**：`PeakLog/Services/SupabaseConfig.swift:19-20`
- **说明**：这是 Supabase publishable/anon key（设计可公开，靠 RLS 保护），不算密钥泄露；但写死无法轮换，`URL(string:)!` 是强制解包代码气味。
- **修复**：① 移入 xcconfig / 构建期注入便于轮换；② 在文档显式确认所有表已启用 RLS；③ `productionURL` 改为 `guard let` 失败报 `.notConfigured`。

### 🟡 [Low] `CompletePlanSetIntent` 未校验 `planSetID` 归属
- **位置**：`PeakLog/PeakLogShared/CompletePlanSetIntent.swift:41-53`
- **修复**：写入前 `attributes.exercises.flatMap(\.sets).contains { $0.id == planSetID }`。

### 🟡 [Low] Keychain 并发写入可能双重 insert / 静默丢会话
- **位置**：`PeakLog/Services/Auth/AuthSessionStore.swift:35-47`
- **修复**：`SecItemUpdate` 非 `errSecItemNotFound` 错误时 log/重试；`save` 加锁或先 `SecItemDelete` 再 `SecItemAdd`（upsert）。

### 🟡 [Low] `AuthView` 直接展示原始后端错误，可能泄露内部细节
- **位置**：`PeakLog/Views/Auth/AuthView.swift:47-53`
- **修复**：对错误脱敏/分类后再展示。

### 🟡 [Low] `deleteNotIn` 把巨大 id 列表拼进 URL query
- **位置**：`PeakLog/Services/Cloud/SupabaseDataClient.swift:69-81`
- **修复**：大表分批或改用 RPC，避免 414。

### 🟡 [Low] 编译进源码的 anon key（同 SupabaseConfig，略）

### 🟡 [Low] `WorkoutDateFormatter` 依赖 `TimeZone.current`，偏好时区字段未参与计算
- **位置**：`PeakLog/Support/WorkoutDateFormatter.swift:8` 等
- **修复**：日期计算统一使用用户偏好时区或 UTC，避免 DST/跨时区错位。

---

## 四、④ 边界异常（Corner Case）

### 🟠 [Medium] `LiveActivity` attributes 可能超 4KB，大计划静默启动失败
- **位置**：`PeakLog/Services/LiveActivityManager.swift:119-139`；`PeakLogShared/PlanLiveActivityAttributes.swift:32-35`
- **问题**：attributes 内含全部动作+组的完整快照；计划较大时 `Activity.request` 抛错，但 `start` 仅 `catch { activity = nil }` 静默吞掉 → 灵动岛/锁屏不显示且后续 update 全部 return。
- **修复**：精简 attributes（仅 id/标题/聚焦），逐组细节移入可更新 `ContentState`；或截断并对失败上报。

### 🟠 [Medium] 长文本未加 lineLimit / minimumScaleFactor
- **位置**：`HistoryCompletedTrainingSection.swift:291, :160`；`TodayWorkoutScreen.swift:461`
- **修复**：标题类加 `.lineLimit(2)` + `.minimumScaleFactor(0.8)`。

### 🟠 [Medium] 动态字体（Dynamic Type）基本不生效
- **位置**：全局（AppTheme.swift 及各 View 多用 `Font.system(size:)`）
- **问题**：`Font.system(size:)` 不随系统字号缩放，辅助功能下文本不放大；大量固定 `frame(height:)` 会挤压内容。
- **修复**：关键文本改用 `Font.TextStyle` 或 Dynamic Type 友好方案。

### 🟠 [Medium] 空状态 / 加载失败占位不足
- **位置**：`PeakLog/Views/Profile/ProfileScreen.swift`（`profile == nil` 时仅弹 alert）
- **修复**：补充专门的空/错误占位视图。

### 🟡 [Low] 体重/自重附加重量负数未校验
- **位置**：`PeakLog/Models/DailyRecordFormModel.swift:80-86`、`PlanExerciseFormModel.swift:35-41`
- **修复**：自重附加重量也应 `>= 0`。

### 🟡 [Low] `WheelValueEditSheet` 滚轮范围固定，超范围初值无法选中
- **位置**：`PeakLog/Views/Today/WheelValueEditSheet.swift:231, :153`（reps 1...50、weight 0...300）
- **修复**：初值 `clamp` 进范围或拓宽范围。

### 🟡 [Low] 启动期 `restore` 与 `onForeground` 时序竞争
- **位置**：`PeakLog/PeakLogApp.swift:21-34`
- **修复**：`onForeground` 内部判断 `auth.state`，未 `signedIn` 时跳过。

### 🟡 [Low] 后台被杀后 Live Activity 用陈旧数据重建
- **位置**：`PeakLog/Services/LiveActivityManager.swift:54-57`
- **修复**：`start` 前确保 `session.exercises` 已是最新。

### 🟡 [Low] `ProfileService.fetchProfile()` 返回非可选，空档案边界未定义
- **位置**：`PeakLog/Services/ProfileService.swift:11-14, 24-26`
- **修复**：返回 `UserProfile?` 或在 DB 层保证带默认偏好的档案。

### 🟡 [Low] iPad vs iPhone 布局
- **位置**：`StatCardView.swift`、`HomeDockBar.swift`
- **修复**：iPad 下限制最大宽度 / 改用多列。

---

## 五、① 多余代码（死代码 / 冗余，均为 Low）

| 位置 | 问题 |
|---|---|
| `LocalAppDatabase.swift:970-972` | `timestampString` 死函数（推送路径用 `CloudDate.timestampString`） |
| `LocalAppDatabase.swift:1067-1071` | `Array.safe` 下标扩展未被使用 |
| `LocalAppDatabase.swift:360-363` | `completePlannedSet` 冗余赋值 + `_ = sessionId` |
| `HistoryCompletedModels.swift:65-66` | `strengthExercises(from:)` 重复调用两次 |
| `CloudRows.swift:19-27` | 成功/失败分支各自 new formatter，可复用/缓存 |
| `TodayWorkoutViewModel.swift:3` | `import CoreGraphics` 未使用 |
| `HistoryViewModel.swift:273-303` | `completePlannedSet` 方法从未被调用（死代码） |
| `AppLanguage.swift:18-25, :61-63` | `speechLocaleIdentifier`、`static func current(preferredLanguages:)` 无生产调用 |
| `LocalizedPlanText.swift:107-120` | `weekdayLabel(dayIndex:locale:)` 仅测试引用 |
| `TodayWorkoutScreen.swift:153, :155` | `.dismissKeyboardOnTap()` 连续调用两次（冗余） |
| `ContentView.swift:34-37` | 重复监听 `scenePhase` 刷新本地化（与 App 层重复） |
| `AuthModels.swift:34` | `AuthError.cancelled` 从未被抛出（疑似死枚举） |
| `TrainingPlanService.swift:104-172` | `EmptyTrainingPlanService` 与 `LocalTrainingPlanService` 100% 重复转发（类名误导） |
| `CloudSyncE2ECheck.swift` | 清理时清空全部 running（仅 DEBUG）；marker 随机碰撞 |

---

## 六、⑤ 优化建议

### 🟠 [Medium] 每次写入全量重算并整体重写 JSON 文件
- **位置**：`PeakLog/Services/LocalAppDatabase.swift:677-740`
- **问题**：`recalculateDerivedProfile` 每次 mutation O(N) 遍历全量；`writeStateToDisk` 用 `encoder.encode(state)` + `.prettyPrinted` 全量序列化写盘。数月训练历史下单次改动即触发全量序列化+原子写。
- **修复**：stats/PR 延迟到读取或缓存失效时计算；生产关 `.prettyPrinted` 或引入分表/SQLite；增量更新 PR/volume。

### 🟠 [Medium] `persistActiveLiveWorkout` 主线程同步编解码+写盘
- **位置**：`PeakLog/ViewModels/TodayWorkoutViewModel.swift:675`
- **问题**：挂在 `activeLiveWorkout.didSet`，每次训练集变更主线程 `JSONEncoder().encode` + `UserDefaults.set`，频繁写入卡主线程。
- **修复**：去抖、仅关键节点落盘、或放后台队列。

### 🟠 [Medium] `ExercisePickerScreen` 重复拉取整个库
- **位置**：`PeakLog/Views/Today/ExercisePickerScreen.swift:444-451, :453-463`
- **修复**：library 缓存到 `@State` 只取一次，recommendation 复用缓存。

### 🟠 [Medium] 网络请求缺超时
- **位置**：`PeakLog/Services/Auth/SupabaseAuthProvider.swift:57-61`
- **修复**：`request.timeoutInterval = 30`。

### 🟠 [Medium] 重复读库（profile / sessions）
- **位置**：`SetDefaultsProvider.swift:78-80`、`ExerciseLibraryService.swift:62-66, 243-264`
- **修复**：缓存 profile 偏好与"上次动作组"，或在 ViewModel 层预取一次后传入；推荐引擎对同选择集 memoization。

### 🟡 [Low] 废弃 API `onChange(of:) { _, new in }`（iOS 17 起废弃）
- **位置**：`AddPlanExerciseSheet.swift:89`、`TodayWorkoutScreen.swift:182/206/219`、`ContentView.swift:34`、`PeakLogApp.swift:30`
- **修复**：迁移到单参 `onChange(of:) { newValue in }`。

### 🟡 [Low] 重复创建 DateFormatter
- **位置**：`RunningRecordCard.swift:49`、`HistoryCompletedTrainingSection.swift:350`、`LocalizedPlanText.swift:108`
- **修复**：抽成静态缓存 formatter（参考 `CalendarGridView` 的缓存模式）。

### 🟡 [Low] `ForEach` + 下标绑定
- **位置**：`WorkoutRecordCard.swift:13`、`ExerciseCardView.swift:184`
- **修复**：改用 `ForEach($record.exercises) { $exercise in ... }` 绑定写法。

### 🟡 [Low] `HistoryScreen` 串行 `await` 可并行
- **位置**：`PeakLog/Views/History/HistoryScreen.swift:22-26`
- **修复**：`async let` 并行加载。

### 🟡 [Low] `HistoryViewModel` 每次 body 求值 new `WorkoutDateFormatter()`
- **位置**：`HistoryViewModel.currentWeekDays()/calendarDays()`
- **修复**：提升为 `lazy`/缓存实例。

### 🟡 [Low] `CloudSnapshotLoader` 一次性把整库读入内存（缺分页/增量，后续扩展点）

### 🟡 [Low] `LiveActivityManager.start` 失败仅静默（同边界项，建议上报）

---

## 七、结论

本次审查覆盖 PeakLog 全部 68 个生产 Swift 文件，共发现 **71 处问题**：**3 处 High（数据正确性与账号安全）**、**18 处 Medium**、**50 处 Low**。总体而言工程结构清晰、actor 隔离与并发自愈设计正确，但存在三类必须优先解决的风险：

1. **单位换算缺陷**（容量统计 + PR 比较）——直接影响展示与排名正确性；
2. **云同步覆盖本地**——离线/DEBUG 数据丢失；
3. **鉴权刷新竞态**——偶发强制登出。

建议按"优先修复清单 Top 5"顺序处理，其余 Low 级问题可纳入日常技术债清理。
