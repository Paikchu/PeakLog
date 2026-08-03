# 开发计划：训练提醒通知（本地通知）

日期：2026-08-02
关联需求：`docs/requirements/2026-08-02-training-reminder-notification.md`

## 1. 现状核实结论

| 事项 | 结论 |
| --- | --- |
| `UserNotifications` 现有引用 | 零。全新接入。 |
| 通知开关 | `UserPreferences.notificationsEnabled` 已存在并同步云端，`ProfileScreen.swift:270` 已有 Toggle，**无消费方**。本期接上。 |
| 计划数据位置 | `LocalAppDatabase`（actor，`activePlan()` 返回完整周计划），本地优先，无需联网即可排程。 |
| Xcode target | 使用 `PBXFileSystemSynchronizedRootGroup`，新增 `.swift` 文件自动入 target，**无需改 project.pbxproj**。 |
| 时区一致性 | `WorkoutDateFormatter` 暴露 `calendar`（时区已绑定），排程复用它构造触发时刻，避免与 `planDate` 日界不一致。 |
| 标题降级 | `TodayPlanHeader.resolve`（`PeakLog/Support/TodayPlanHeaderModel.swift`）已有，直接复用。 |
| entitlement | 本地通知无需 entitlement，`PeakLog.entitlements` 不改。 |

## 2. 改动文件

### 新增

| 文件 | 职责 |
| --- | --- |
| `PeakLog/Support/TrainingReminderSchedule.swift` | **纯逻辑**：`TrainingReminderTime`、`TrainingReminderRequest`、`TrainingReminderSchedule.requests(...)`。只 import Foundation，不碰 `UserNotifications`，可用 swiftc 独立编译测试。 |
| `PeakLog/Services/TrainingReminderScheduler.swift` | `@MainActor ObservableObject`：持有授权状态与提醒时间（UserDefaults），把纯逻辑产出的请求翻译成 `UNNotificationRequest` 并落到 `UNUserNotificationCenter`；本地化文案在此层组装。通知中心以协议注入，便于替身。 |
| `PeakLog/Views/Profile/ReminderTimePickerSheet.swift` | 提醒时间选择 sheet（`DatePicker` wheel，仅时分）。 |
| `tests/training_reminder_schedule_test.swift` | 排程规则回归测试（休息日、已开始、过时刻、开关关闭、时间变更）。 |

### 修改

| 文件 | 改动 |
| --- | --- |
| `PeakLog/PeakLogApp.swift` | 构造 `TrainingReminderScheduler`，注入 environmentObject；`scenePhase` 变为 `.active` / `.background` 时触发重排。 |
| `PeakLog/Views/Profile/ProfileScreen.swift` | 通知 Toggle 打开时申请授权并重排；新增「提醒时间」`PreferenceNavRow` + sheet；授权被拒时显示引导文案。 |
| `PeakLog/Localizable.xcstrings` | 新增通知文案与 Profile 文案键（en / zh-Hans）。 |

## 3. 排程规则（纯函数契约）

输入：`plan: TrainingPlan?`、`now: Date`、`reminderTime`、`isEnabled: Bool`、`formatter: WorkoutDateFormatter`

输出：`[TrainingReminderRequest]`，按日期升序，最多 7 条。

逐日过滤：`planDate >= today` → `exercises` 非空 → `completedProgressUnits == 0` → 触发时刻 `> now`。

标识符 `peaklog.training-reminder.<planDate>`，重排时按前缀清理，避免误删其他功能未来可能添加的通知。

## 4. 测试矩阵

| 层 | 覆盖 |
| --- | --- |
| `tests/training_reminder_schedule_test.swift`（swiftc 独立运行） | 开关关闭 / 无计划 / 休息日 / 已开始 / 今日时刻已过 / 今日时刻未到 / 跨月边界 / 排序与上限 / 标识符前缀 |
| `xcodebuild build` | 全量编译（含新文件与 xcstrings） |
| 模拟器（iPhone 17 Pro Max, iOS 26.5） | 授权弹窗、开关打开/关闭、修改提醒时间、休息日无提醒 |

## 5. 风险与回滚

- **风险**：服务端 replan 后未打开 App 则排程滞后。缓解：每次前台全量重排；已在需求文档记录为已知取舍。
- **风险**：用户系统语言切换后，已排程通知仍是旧语言。缓解：前台重排时重建全部请求。
- **回滚**：功能全部为设备本地、无迁移、无线上部署；回滚 = revert commit，残留的 pending 通知在下次启动（无排程代码）后不再重建，最多残留一周内已排的请求。

## 6. 执行顺序

1. 纯逻辑 + 独立测试（先红后绿）。
2. Scheduler 服务层。
3. Profile UI + 本地化。
4. App 生命周期接线。
5. 构建 + 模拟器验收。
