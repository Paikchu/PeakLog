import Foundation

/// 训练提醒的触发时刻（时:分）。
///
/// 设备本地设置，不参与云端同步——比照 `ThemeManager` 的 appearance：
/// 提醒发生在"用户此刻人在的这台设备上"，跨设备统一没有意义，也就不值得
/// 为它动 Supabase schema 和同步契约。
nonisolated struct TrainingReminderTime: Equatable, Sendable {
    let hour: Int
    let minute: Int

    static let `default` = TrainingReminderTime(hour: 18, minute: 0)

    /// 越界值被夹取而不是拒绝：唯一的写入源是 UI 上的 `DatePicker`，
    /// 夹取只在存储被外部改坏时兜底，没必要让调用方处理失败分支。
    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    /// `UserDefaults` 存储格式，固定 "HH:mm"，与语言/地区无关。
    var storageValue: String {
        String(format: "%02d:%02d", hour, minute)
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    /// 展示用文案。走 `timeStyle = .short` 而不是自己拼 "HH:mm"，
    /// 英文环境下才会得到 "6:00 PM" 而不是 "18:00"。
    func localizedDisplay(locale: Locale) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        guard let date = Calendar.current.date(from: components) else { return storageValue }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

/// 一条待排程的训练提醒。
///
/// 刻意只携带**结构化素材**（计划标题、focus、动作数），不携带成品文案：
/// 本地化要在排程那一刻按当前语言求值，那是 `TrainingReminderScheduler`
/// 的职责。这样这一层保持纯 Foundation，能被 `tests/` 下的 swiftc 脚本
/// 独立编译验证。
nonisolated struct TrainingReminderRequest: Equatable, Sendable {
    let planDate: String
    let dateComponents: DateComponents
    let planTitle: String
    let focus: String?
    let exerciseCount: Int

    var identifier: String {
        TrainingReminderSchedule.identifierPrefix + planDate
    }
}

/// 决定"哪几天该提醒、几点提醒"的纯函数。
///
/// iOS 不允许在通知触发那一刻跑逻辑（判断今天是不是休息日、有没有练过），
/// 只能预先排程。所以这里一次性算出未来若干天各自的触发时刻，由调用方
/// 全量重排（先按 `identifierPrefix` 清空再重建）。
nonisolated enum TrainingReminderSchedule {
    /// 带前缀是为了重排时只清理本功能的请求，不误删将来别处添加的通知。
    static let identifierPrefix = "peaklog.training-reminder."

    /// 激活计划本身就是 7 日周期，这里的上限只是防御：计划数据异常膨胀时
    /// 不至于把 iOS 每 App 64 条的待定通知配额一次占满。
    static let maxRequests = 7

    /// - Parameters:
    ///   - plan: 当前激活的周计划；`nil`（尚未生成计划）时不提醒。
    ///   - now: 当前时刻，注入以便测试。
    ///   - isEnabled: 用户的通知总开关（`UserPreferences.notificationsEnabled`）。
    ///   - formatter: 提供 `planDate` 的解析口径**和**与之绑定的时区日历。
    ///     两者必须同源，否则 "2026-08-03 的 18:00" 会算到别的日界上去。
    static func requests(
        plan: TrainingPlan?,
        now: Date,
        reminderTime: TrainingReminderTime,
        isEnabled: Bool,
        formatter: WorkoutDateFormatter = WorkoutDateFormatter()
    ) -> [TrainingReminderRequest] {
        guard isEnabled, let plan else { return [] }

        let calendar = formatter.calendar
        let todayKey = formatter.string(from: now)

        // planDate 是零填充的 "yyyy-MM-dd"，字典序即时间序，无需转成 Date 再比。
        let upcoming = plan.days
            .filter { $0.planDate >= todayKey }
            .sorted { $0.planDate < $1.planDate }

        var results: [TrainingReminderRequest] = []
        for day in upcoming {
            guard results.count < maxRequests else { break }

            // 没有动作 = 休息日，不打扰。
            guard !day.exercises.isEmpty else { continue }
            // 已经开始练了就说明没忘，这条提醒只会是噪音。
            guard day.completedProgressUnits == 0 else { continue }

            guard let dayStart = formatter.date(from: day.planDate),
                  let fireDate = calendar.date(
                      bySettingHour: reminderTime.hour,
                      minute: reminderTime.minute,
                      second: 0,
                      of: dayStart
                  ),
                  // 今天的提醒时刻已过就跳过：带完整年月日的非重复触发器排在
                  // 过去只会静默永不触发，白占一个配额。
                  fireDate > now else { continue }

            var components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )
            // 显式带上日历与时区，否则 `UNCalendarNotificationTrigger` 会按
            // `Calendar.current` 解释这组分量，与上面算 fireDate 用的口径可能不一致。
            components.calendar = calendar
            components.timeZone = calendar.timeZone

            results.append(TrainingReminderRequest(
                planDate: day.planDate,
                dateComponents: components,
                planTitle: day.title,
                focus: day.focus,
                exerciseCount: day.exercises.count
            ))
        }
        return results
    }
}
