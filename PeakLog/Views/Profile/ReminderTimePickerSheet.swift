import SwiftUI

/// 训练提醒时刻选择。
///
/// 用 `DatePicker` 的 `.hourAndMinute` 而不是两个 Picker：系统组件自带
/// 12/24 小时制与地区习惯的处理，自己拼时分轮会在英文环境下丢掉 AM/PM。
struct ReminderTimePickerSheet: View {
    let initial: TrainingReminderTime
    let onSave: (TrainingReminderTime) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Date

    init(initial: TrainingReminderTime, onSave: @escaping (TrainingReminderTime) async -> Void) {
        self.initial = initial
        self.onSave = onSave
        // DatePicker 只读时分，日期取哪天无所谓；用今天避开构造无效 Date。
        _selection = State(initialValue: Calendar.current.date(
            bySettingHour: initial.hour, minute: initial.minute, second: 0, of: Date()
        ) ?? Date())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker(
                    "profile.preferences.reminder_time",
                    selection: $selection,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()

                Text("profile.preferences.reminder_time.hint")
                    .appFont(size: 13)
                    .foregroundColor(.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()
            }
            .padding(.top, 20)
            .frame(maxWidth: .infinity)
            .background(Color.appBackground)
            .navigationTitle("profile.preferences.reminder_time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done") {
                        let components = Calendar.current.dateComponents([.hour, .minute], from: selection)
                        let time = TrainingReminderTime(
                            hour: components.hour ?? initial.hour,
                            minute: components.minute ?? initial.minute
                        )
                        dismiss()
                        Task { await onSave(time) }
                    }
                }
            }
        }
    }
}
