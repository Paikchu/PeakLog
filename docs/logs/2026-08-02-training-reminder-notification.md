# 交付记录：训练提醒本地通知

**日期**：2026-08-02
**关联**：`docs/requirements/2026-08-02-training-reminder-notification.md`、`docs/plans/2026-08-02-training-reminder-notification-plan.md`

## 实现改动

### 新增

- `PeakLog/Support/TrainingReminderSchedule.swift`：纯逻辑层。`TrainingReminderTime`（时刻 + `HH:mm` 存储格式 + 本地化展示）、`TrainingReminderRequest`（结构化素材，不含成品文案）、`TrainingReminderSchedule.requests(...)`（决定哪几天该提醒）。只依赖 Foundation。
- `PeakLog/Services/TrainingReminderScheduler.swift`：`@MainActor ObservableObject`。持有提醒时刻（UserDefaults `peaklog.trainingReminderTime`）与系统授权状态，把纯逻辑产出翻译成 `UNNotificationRequest`。通知中心以 `TrainingReminderNotifying` 协议注入。
- `PeakLog/Views/Profile/ReminderTimePickerSheet.swift`：提醒时刻选择（`DatePicker` `.hourAndMinute`，自动处理 12/24 小时制）。
- `tests/training_reminder_schedule_test.swift`：排程规则回归测试。

### 修改

- `PeakLog/PeakLogApp.swift`：注入 `TrainingReminderScheduler`；`scenePhase` 进 `.active`/`.background`、以及 `syncController.isPreparingSession` 落回 `false`（pull 落地）时全量重排。
- `PeakLog/Views/Profile/ProfileScreen.swift`：通知开关接上授权与重排；新增「提醒时间」行与被拒引导文案。
- `PeakLog/ViewModels/ProfileViewModel.swift`：`toggleNotifications()` → `setNotificationsEnabled(_:)`（见下方决策）。
- `PeakLog/Localizable.xcstrings`：新增 5 个 key（en / zh-Hans），其中通知正文带英文复数变体。

## 过程中的两个非预期修正

1. **开关此前是「死开关」，且默认值会造成静默失效**。`notificationsEnabled` 早已存在并同步云端，但全仓库无消费方。接上后模拟器验收暴露：该偏好默认 `true`，而系统授权是 `.notDetermined`，于是新用户看到「通知 开启」却永远收不到通知、也永远不会被问是否允许。改为**开关显示有效状态（偏好 ∧ 系统授权）**，并把 ViewModel 的 `toggleNotifications()` 改成 `setNotificationsEnabled(_:)`——显示值不再是存储值的取反，翻转语义会算错。
2. **英文复数**。首轮真机文案是 `1 exercises`。项目此前没有任何复数处理先例；本次给正文加了 xcstrings substitution 变体，并在 scheduler 用 `String.localizedStringWithFormat`（而非项目常用的 `LocalizedPlanText.formatted`，后者走 `String(format:)`，解析不了 `%#@count@` 模板）。

## 验证结果

| 项 | 结果 |
| --- | --- |
| `tests/training_reminder_schedule_test.swift`（swiftc 独立运行） | 通过（开关关闭 / 无计划 / 休息日 / 已开始 / 时刻已过 / 边界等于时刻 / 改时间 / 过去日 / 跨月 / 上限 / 标识符前缀 / 存储往返与夹取） |
| `tests/profile_static_affordance_test.swift` | 通过（改动 `ProfileScreen` 后回归） |
| `xcodebuild test`（iPhone 17 Pro Max, iOS 26.5，串行） | 141 tests, 0 failures |
| `xcodebuild build` | BUILD SUCCEEDED |
| 模拟器：全新安装 | 开关显示 Off、无提醒时间行 ✅ |
| 模拟器：打开开关 → Don't Allow | 开关回落 Off、提醒时间行消失、引导文案出现 ✅ |
| 模拟器：打开开关 → Allow | 开关 On、提醒时间行出现（英文显示 6:00 PM）✅ |
| 模拟器：真实送达 | 到点弹出「Don't forget today's workout / Today: Today's Training · 1 exercise」✅ |
| 模拟器：已完成当日训练后退到后台 | 到点无通知（当日待定请求被移除）✅ |

## 未覆盖 / 残余风险

- **服务端 replan 后排程滞后**：用户不打开 App 时，本地排程停留在旧计划，直到下次前台重排。选择本地通知路径的已知代价。
- **休息日路径未在模拟器手测**：由纯逻辑测试覆盖（`exercises` 为空即跳过），未在真机上专门造一个休息日复验。
- **系统语言切换后已排程通知仍是旧语言**，由下次前台重排覆盖，未专门验证。
- 通知点击后仅打开 App 到默认页，未做深链。
- 远程推送（APNs）按需求约定不在本期范围，留作后续独立需求。

## 部署与回滚

- Supabase：**无任何改动**（无迁移、无 RLS、无 Edge Function、无线上部署）。
- 回滚：revert commit 即可。功能全部设备本地；回滚后残留的待定通知不再被重建，最多残留一周内已排的请求。
