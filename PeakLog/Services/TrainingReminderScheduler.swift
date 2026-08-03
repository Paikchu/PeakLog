import Combine
import Foundation
import UserNotifications

/// `UNUserNotificationCenter` 的最小可替身面。只暴露本功能真正用到的四个
/// 动作，这样测试和预览可以塞入替身，而不必让整个调度器依赖系统单例。
protocol TrainingReminderNotifying: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func removePendingRequests(withPrefix prefix: String) async
    func add(_ request: UNNotificationRequest) async throws
}

struct SystemTrainingReminderNotifier: TrainingReminderNotifying {
    private var center: UNUserNotificationCenter { .current() }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        // 用户点「不允许」不是错误，只是结果为 false；真正抛错（极罕见的
        // 系统故障）也按未授权处理，调用方只关心"能不能排程"。
        ((try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false)
    }

    func removePendingRequests(withPrefix prefix: String) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
}

/// 训练提醒的唯一入口：读取计划与偏好 → 交给 `TrainingReminderSchedule`
/// 算出该排哪几条 → 落到系统通知中心。
///
/// 采用**全量重排**（先按前缀清空再重建）而不是增量维护：计划、完成进度、
/// 提醒时间、App 语言都可能在任意时刻变化，逐条 diff 的分支数远多于重建，
/// 而重建的成本只是最多 7 条本地通知。
@MainActor
final class TrainingReminderScheduler: ObservableObject {
    private static let reminderTimeKey = "peaklog.trainingReminderTime"

    /// 提醒时刻（设备本地）。
    @Published private(set) var reminderTime: TrainingReminderTime

    /// 系统层面确实能送达通知（已授权 / 临时授权）。
    ///
    /// Profile 的开关显示的是**有效状态**（偏好 ∧ 本值）而不是单看偏好：
    /// `notificationsEnabled` 默认就是 `true`，若只看它，全新安装的用户会
    /// 看到一个写着"开启"、却因为从没申请过授权而永远不响的开关。
    @Published private(set) var isSystemAuthorized = false

    /// 用户在系统设置里明确拒绝过通知。此时开关打开也排不出通知，
    /// Profile 据此显示"去系统设置打开"的引导，而不是假装已生效。
    @Published private(set) var isSystemAuthorizationDenied = false

    private let notifier: TrainingReminderNotifying
    private let profileService: ProfileServiceProtocol
    private let planService: TrainingPlanServiceProtocol
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(
        notifier: TrainingReminderNotifying = SystemTrainingReminderNotifier(),
        profileService: ProfileServiceProtocol = AppServices.profileService,
        planService: TrainingPlanServiceProtocol = AppServices.trainingPlanService,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.notifier = notifier
        self.profileService = profileService
        self.planService = planService
        self.defaults = defaults
        self.now = now
        self.reminderTime = defaults.string(forKey: Self.reminderTimeKey)
            .flatMap(TrainingReminderTime.init(storageValue:))
            ?? .default
    }

    // MARK: - Public API

    /// 按当前计划与偏好全量重排。进前台、退后台、改设置后都调它。
    func refresh() async {
        let status = await notifier.authorizationStatus()
        apply(status)

        // 先无条件清空：开关关闭、授权被撤销、计划变成休息日等情况都要求
        // 旧的待定通知消失，而这些分支下面会提前 return，清理必须在前面。
        await notifier.removePendingRequests(withPrefix: TrainingReminderSchedule.identifierPrefix)

        guard isSystemAuthorized else { return }

        let isEnabled = (try? await profileService.fetchProfile())?.preferences.notificationsEnabled ?? false
        guard isEnabled else { return }

        let plan = try? await planService.fetchActiveWeeklyPlan()
        let requests = TrainingReminderSchedule.requests(
            plan: plan,
            now: now(),
            reminderTime: reminderTime,
            isEnabled: isEnabled
        )

        for request in requests {
            try? await notifier.add(makeSystemRequest(from: request))
        }
    }

    /// 用户打开通知开关时调用：首次会弹系统授权框。
    /// - Returns: 是否拿到了可用授权。调用方据此决定开关是否留在打开状态。
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        var status = await notifier.authorizationStatus()
        if status == .notDetermined {
            // 授权框只在用户主动开开关时弹，不在启动时打扰。
            _ = await notifier.requestAuthorization()
            status = await notifier.authorizationStatus()
        }
        apply(status)
        return isSystemAuthorized
    }

    private func apply(_ status: UNAuthorizationStatus) {
        isSystemAuthorized = status == .authorized || status == .provisional || status == .ephemeral
        isSystemAuthorizationDenied = status == .denied
    }

    func setReminderTime(_ time: TrainingReminderTime) async {
        guard time != reminderTime else { return }
        reminderTime = time
        defaults.set(time.storageValue, forKey: Self.reminderTimeKey)
        await refresh()
    }

    // MARK: - Content

    /// 文案在排程这一刻按当前语言求值。系统语言切换后旧请求仍是旧语言，
    /// 由下一次前台重排覆盖（见计划文档的已知取舍）。
    private func makeSystemRequest(from request: TrainingReminderRequest) -> UNNotificationRequest {
        let header = TodayPlanHeader.resolve(
            planTitle: request.planTitle,
            focus: request.focus,
            fallbackTitle: String(localized: "today.header.default_title")
        )

        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.training_reminder.title")
        // `String.localizedStringWithFormat`, not the app's usual
        // `LocalizedPlanText.formatted`: the body carries a plural substitution
        // ("1 exercise" vs "2 exercises") and plain `String(format:)` leaves the
        // `%#@count@` template unresolved.
        content.body = String.localizedStringWithFormat(
            String(localized: "notification.training_reminder.body"),
            header.title,
            Int64(request.exerciseCount)
        )
        content.sound = .default

        return UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: request.dateComponents, repeats: false)
        )
    }
}
