import SwiftUI

// MARK: - Shared Chrome
// Title + optional "last time" hint (tap to apply it) + wheel content +
// Cancel/Done. No keyboard involved, so there's no focus race and no
// keyboard-accessory toolbar competing with the sheet's own Done button.

private struct WheelSheetChrome<Content: View>: View {
    let titleKey: String
    let lastTimeText: String?
    var onLastTimeTap: (() -> Void)?
    let onCancel: () -> Void
    let onDone: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 14) {
            Text(String(localized: String.LocalizationValue(titleKey)))
                .appFont(.headerTitle)
                .foregroundColor(.textPrimary)
                .padding(.top, 20)

            if let lastTimeText {
                Button {
                    onLastTimeTap?()
                } label: {
                    HStack(spacing: 4) {
                        Text("chat.exercise.last_time")
                        Text(lastTimeText)
                            .foregroundColor(.textSecondary)
                    }
                    .appFont(size: 12, weight: .medium)
                    .foregroundColor(.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.workoutPanel))
                }
                .buttonStyle(.plain)
            }

            content()

            HStack(spacing: 16) {
                Button(String(localized: "common.cancel")) { onCancel() }
                    .foregroundColor(.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.appSurface)
                    .cornerRadius(AppRadius.lg)

                Button(String(localized: "common.done")) { onDone() }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(LinearGradient.accentGradient)
                    .cornerRadius(AppRadius.lg)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .background(Color.appCard)
    }
}

// MARK: - Weight Wheel Sheet

struct WeightWheelEditSheet: View {
    /// True for exercises whose loadType is `.bodyweight` — shows the
    /// Bodyweight/Added-Weight segmented control above the wheel.
    let allowsBodyweightToggle: Bool
    let weightUnit: WeightUnit
    /// Current stored value; nil means bodyweight-with-no-added-weight
    /// (or, for a non-bodyweight exercise, simply unset).
    let initialWeight: Double?
    let lastTime: SetDefaultsSuggestion?
    var onDone: (Double?) -> Void
    var onCancel: () -> Void

    @State private var isBodyweight: Bool
    @State private var whole: Int
    @State private var fractionIndex: Int

    private static let fractionValues: [Double] = [0, 0.25, 0.5, 0.75]
    private static let wholeRange = Array(0...300)

    init(
        allowsBodyweightToggle: Bool,
        weightUnit: WeightUnit,
        initialWeight: Double?,
        lastTime: SetDefaultsSuggestion?,
        onDone: @escaping (Double?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.allowsBodyweightToggle = allowsBodyweightToggle
        self.weightUnit = weightUnit
        self.initialWeight = initialWeight
        self.lastTime = lastTime
        self.onDone = onDone
        self.onCancel = onCancel

        _isBodyweight = State(initialValue: allowsBodyweightToggle && initialWeight == nil)
        let baseline = initialWeight ?? lastTime?.weight ?? 20
        _whole = State(initialValue: max(0, min(300, Int(baseline))))
        _fractionIndex = State(initialValue: Self.nearestFractionIndex(baseline))
    }

    private static func nearestFractionIndex(_ value: Double) -> Int {
        let fraction = value.truncatingRemainder(dividingBy: 1)
        return fractionValues.indices.min { lhs, rhs in
            abs(fractionValues[lhs] - fraction) < abs(fractionValues[rhs] - fraction)
        } ?? 0
    }

    private var currentWeight: Double {
        Double(whole) + Self.fractionValues[fractionIndex]
    }

    private var lastTimeText: String? {
        guard let lastTime else { return nil }
        return LoadDisplayFormat.plainText(
            weight: lastTime.weight,
            unit: lastTime.weightUnit,
            isBodyweight: allowsBodyweightToggle
        )
    }

    var body: some View {
        WheelSheetChrome(
            titleKey: "chat.exercise.edit_weight",
            lastTimeText: lastTimeText,
            onLastTimeTap: applyLastTime,
            onCancel: onCancel,
            onDone: { onDone(isBodyweight ? nil : currentWeight) }
        ) {
            VStack(spacing: 10) {
                if allowsBodyweightToggle {
                    Picker("", selection: $isBodyweight) {
                        Text("chat.exercise.bodyweight").tag(true)
                        Text("chat.exercise.load_mode.added").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 32)
                }

                if isBodyweight {
                    Text("chat.exercise.bodyweight")
                        .appFont(size: 32, weight: .bold, design: .rounded)
                        .foregroundColor(.accentValue)
                        .frame(height: 150)
                } else {
                    HStack(spacing: 2) {
                        Picker("", selection: $whole) {
                            ForEach(Self.wholeRange, id: \.self) { value in
                                Text("\(value)").tag(value)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 84)

                        Text(".")
                            .appFont(size: 20, weight: .semibold)
                            .foregroundColor(.textSecondary)

                        Picker("", selection: $fractionIndex) {
                            ForEach(Self.fractionValues.indices, id: \.self) { index in
                                Text(String(format: "%02d", Int(Self.fractionValues[index] * 100))).tag(index)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 68)

                        Text(weightUnit.display)
                            .appFont(.settingTitle)
                            .foregroundColor(.textMuted)
                            .padding(.leading, 4)
                    }
                    .frame(height: 150)
                }
            }
        }
    }

    private func applyLastTime() {
        guard let lastTime else { return }
        if allowsBodyweightToggle, lastTime.weight == nil {
            isBodyweight = true
            return
        }
        isBodyweight = false
        let value = lastTime.weight ?? 0
        whole = max(0, min(300, Int(value)))
        fractionIndex = Self.nearestFractionIndex(value)
    }
}

// MARK: - Reps Wheel Sheet

struct RepsWheelEditSheet: View {
    let initialReps: Int
    let lastTime: SetDefaultsSuggestion?
    var onDone: (Int) -> Void
    var onCancel: () -> Void

    @State private var reps: Int

    init(
        initialReps: Int,
        lastTime: SetDefaultsSuggestion?,
        onDone: @escaping (Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialReps = initialReps
        self.lastTime = lastTime
        self.onDone = onDone
        self.onCancel = onCancel
        _reps = State(initialValue: initialReps > 0 ? initialReps : (lastTime?.reps ?? 8))
    }

    var body: some View {
        WheelSheetChrome(
            titleKey: "chat.exercise.edit_reps",
            lastTimeText: lastTime?.reps.map { "\($0)" },
            onLastTimeTap: {
                if let lastReps = lastTime?.reps { reps = lastReps }
            },
            onCancel: onCancel,
            onDone: { onDone(reps) }
        ) {
            HStack(spacing: 8) {
                Picker("", selection: $reps) {
                    ForEach(1...50, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: 100, height: 150)

                Text("chat.exercise.reps")
                    .appFont(.settingTitle)
                    .foregroundColor(.textMuted)
            }
        }
    }
}
