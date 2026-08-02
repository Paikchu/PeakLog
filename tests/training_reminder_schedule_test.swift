import Foundation

// Logic test: 训练提醒的排程规则（休息日 / 已开始 / 时刻已过 / 总开关 / 排序上限）。
// 验收命令：
//   swiftc -parse-as-library \
//     PeakLog/Models/WorkoutModels.swift PeakLog/Models/TrainingPlanModels.swift \
//     PeakLog/Support/WorkoutDateFormatter.swift PeakLog/Support/TrainingReminderSchedule.swift \
//     tests/training_reminder_schedule_test.swift -o /tmp/trs && /tmp/trs

@main
struct TrainingReminderScheduleTest {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    static let formatter = WorkoutDateFormatter(timeZone: timeZone)
    static let reminderTime = TrainingReminderTime(hour: 18, minute: 0)

    static func set(completed: Bool) -> TrainingPlanSet {
        TrainingPlanSet(
            id: "set-\(UUID().uuidString)",
            setIndex: 0,
            targetWeight: 60,
            targetWeightUnit: .kg,
            targetReps: 8,
            completedAt: completed ? Date() : nil,
            linkedExerciseSetId: nil
        )
    }

    static func exercise(completedSets: Int, totalSets: Int) -> TrainingPlanExercise {
        TrainingPlanExercise(
            id: "ex-\(UUID().uuidString)",
            orderIndex: 0,
            exerciseName: "Bench Press",
            exerciseLoadType: .weighted,
            progressionMode: "linear",
            notes: nil,
            previousPerformanceSummary: nil,
            aiSuggestion: nil,
            sets: (0..<totalSets).map { set(completed: $0 < completedSets) }
        )
    }

    static func day(
        _ planDate: String,
        title: String = "Push Day",
        focus: String? = "Chest",
        exercises: [TrainingPlanExercise]
    ) -> TrainingPlanDay {
        TrainingPlanDay(
            id: "day-\(planDate)",
            planDate: planDate,
            dayIndex: 0,
            title: title,
            focus: focus,
            status: "planned",
            exercises: exercises
        )
    }

    static func plan(_ days: [TrainingPlanDay]) -> TrainingPlan {
        TrainingPlan(
            id: "plan-1",
            weekStartDate: days.first?.planDate ?? "2026-08-03",
            goalSummary: nil,
            coachSummary: "",
            days: days
        )
    }

    static func requests(
        _ plan: TrainingPlan?,
        now: String,
        isEnabled: Bool = true,
        time: TrainingReminderTime = reminderTime
    ) -> [TrainingReminderRequest] {
        // "yyyy-MM-dd HH:mm" 的 now，避开各测试各写一遍构造 Date 的样板。
        let parts = now.split(separator: " ")
        let dayStart = formatter.date(from: String(parts[0]))!
        let clock = parts[1].split(separator: ":")
        let nowDate = formatter.calendar.date(
            bySettingHour: Int(clock[0])!, minute: Int(clock[1])!, second: 0, of: dayStart
        )!
        return TrainingReminderSchedule.requests(
            plan: plan,
            now: nowDate,
            reminderTime: time,
            isEnabled: isEnabled,
            formatter: formatter
        )
    }

    static func main() {
        let trainingDay = day("2026-08-03", exercises: [exercise(completedSets: 0, totalSets: 3)])
        let restDay = day("2026-08-04", title: "Rest", focus: nil, exercises: [])
        let laterDay = day("2026-08-05", title: "Pull Day", focus: "Back", exercises: [
            exercise(completedSets: 0, totalSets: 4)
        ])
        let fullWeek = plan([trainingDay, restDay, laterDay])

        // 总开关关闭 → 一条都不排。
        precondition(
            requests(fullWeek, now: "2026-08-03 09:00", isEnabled: false).isEmpty,
            "通知开关关闭时不应排程任何提醒"
        )

        // 尚未生成计划 → 一条都不排。
        precondition(requests(nil, now: "2026-08-03 09:00").isEmpty, "无激活计划时不应排程提醒")

        // 基础路径：今天有训练且时刻未到 → 今天与后续训练日各一条，休息日被跳过。
        let base = requests(fullWeek, now: "2026-08-03 09:00")
        precondition(base.map(\.planDate) == ["2026-08-03", "2026-08-05"], "休息日不应产生提醒，且结果按日期升序")
        precondition(base[0].exerciseCount == 1, "动作数应取当日计划动作条目数")
        precondition(base[1].planTitle == "Pull Day" && base[1].focus == "Back", "标题与 focus 应原样透传给文案层")

        // 触发时刻按 reminderTime 落在当天。
        let first = base[0].dateComponents
        precondition(
            first.year == 2026 && first.month == 8 && first.day == 3 && first.hour == 18 && first.minute == 0,
            "触发时刻应为计划当天的提醒时间"
        )
        precondition(first.timeZone == timeZone, "触发分量必须带时区，否则会被按 Calendar.current 解释")

        // 今天的提醒时刻已过 → 跳过今天，保留后续日期。
        let afterHour = requests(fullWeek, now: "2026-08-03 19:30")
        precondition(afterHour.map(\.planDate) == ["2026-08-05"], "提醒时刻已过的当天不应再排程")

        // 正好等于提醒时刻也算已过（严格大于）。
        precondition(
            requests(fullWeek, now: "2026-08-03 18:00").map(\.planDate) == ["2026-08-05"],
            "now 等于触发时刻时应视为已过"
        )

        // 修改提醒时间 → 触发时刻与是否已过同步变化。
        let earlyMorning = requests(fullWeek, now: "2026-08-03 09:00", time: TrainingReminderTime(hour: 7, minute: 30))
        precondition(earlyMorning.map(\.planDate) == ["2026-08-05"], "改到 07:30 后，今天的时刻已过应被跳过")
        precondition(
            earlyMorning[0].dateComponents.hour == 7 && earlyMorning[0].dateComponents.minute == 30,
            "触发时刻应跟随提醒时间设置"
        )

        // 当天已开始训练（任意一组完成）→ 不再提醒。
        let startedToday = plan([
            day("2026-08-03", exercises: [exercise(completedSets: 1, totalSets: 3)]),
            laterDay
        ])
        precondition(
            requests(startedToday, now: "2026-08-03 09:00").map(\.planDate) == ["2026-08-05"],
            "已开始训练的日子不应再提醒"
        )

        // 过去的日子不排程。
        let withPast = plan([day("2026-08-01", exercises: [exercise(completedSets: 0, totalSets: 3)]), laterDay])
        precondition(
            requests(withPast, now: "2026-08-03 09:00").map(\.planDate) == ["2026-08-05"],
            "过去的计划日不应排程"
        )

        // 跨月边界：8/31 → 9/1 的日期分量正确。
        let crossMonth = plan([
            day("2026-08-31", exercises: [exercise(completedSets: 0, totalSets: 3)]),
            day("2026-09-01", exercises: [exercise(completedSets: 0, totalSets: 3)])
        ])
        let crossed = requests(crossMonth, now: "2026-08-31 09:00")
        precondition(crossed.map(\.planDate) == ["2026-08-31", "2026-09-01"], "跨月的两天都应排程")
        precondition(
            crossed[1].dateComponents.month == 9 && crossed[1].dateComponents.day == 1,
            "跨月后的日期分量应进位到 9 月 1 日"
        )

        // 标识符带统一前缀，重排时才能只清理本功能的请求。
        precondition(
            crossed[0].identifier == "peaklog.training-reminder.2026-08-31",
            "标识符应为前缀 + planDate"
        )
        precondition(
            crossed.allSatisfy { $0.identifier.hasPrefix(TrainingReminderSchedule.identifierPrefix) },
            "所有请求都必须带统一前缀"
        )

        // 上限：计划异常膨胀时不占满 iOS 的待定通知配额。
        let bloated = plan((3...20).map {
            day(String(format: "2026-08-%02d", $0), exercises: [exercise(completedSets: 0, totalSets: 3)])
        })
        precondition(
            requests(bloated, now: "2026-08-03 09:00").count == TrainingReminderSchedule.maxRequests,
            "排程条数应受 maxRequests 限制"
        )

        // 存储格式往返，含越界夹取。
        precondition(TrainingReminderTime(hour: 7, minute: 5).storageValue == "07:05", "存储格式应零填充")
        precondition(TrainingReminderTime(storageValue: "07:05") == TrainingReminderTime(hour: 7, minute: 5), "往返应一致")
        precondition(TrainingReminderTime(storageValue: "25:00") == nil, "越界字符串应解析失败")
        precondition(TrainingReminderTime(storageValue: "abc") == nil, "非法字符串应解析失败")
        precondition(TrainingReminderTime(hour: 99, minute: 99) == TrainingReminderTime(hour: 23, minute: 59), "越界值应被夹取")

        print("training_reminder_schedule_test passed")
    }
}
