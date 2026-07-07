import SwiftUI

// MARK: - Load Display
// A logged/target weight is either a plain number (weighted exercise) or,
// for bodyweight exercises, either bare "Bodyweight" or "Bodyweight +20kg"
// once an added-weight vest/dumbbell/belt is in play. Centralized here so
// every set row (today session, plan target, manual record, history) reads
// the same rule instead of re-deriving it.

enum LoadDisplayFormat {
    static func plainText(weight: Double?, unit: WeightUnit, isBodyweight: Bool) -> String {
        let bodyweightLabel = String(localized: "chat.exercise.bodyweight")
        if isBodyweight {
            guard let weight, weight > 0 else { return bodyweightLabel }
            return "\(bodyweightLabel) +\(formatWeightValue(weight))\(unit.display)"
        }
        guard let weight else { return bodyweightLabel }
        return "\(formatWeightValue(weight))\(unit.display)"
    }
}

/// Themed replacement for the ad-hoc `HStack(Text(weight), Text(unit))` that
/// used to appear in every set row — now also renders the bodyweight
/// "+ added weight" combination consistently.
struct LoadValueLabel: View {
    let weight: Double?
    let weightUnit: WeightUnit
    let isBodyweight: Bool
    /// Shown when `weight` is nil and this isn't a bodyweight exercise —
    /// e.g. a weighted plan target the user hasn't set a weight for yet.
    /// Defaults to the bodyweight label, which is correct wherever "no
    /// weight" only ever means bodyweight.
    var unsetPlaceholder: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if isBodyweight {
                Text("chat.exercise.bodyweight")
                    .font(.exerciseValue)
                    .foregroundColor(.accentValue)
                if let weight, weight > 0 {
                    Text("+\(formatWeightValue(weight))")
                        .font(.exerciseValue)
                        .foregroundColor(.accentValue)
                    Text(weightUnit.display)
                        .font(.exerciseUnit)
                        .foregroundColor(.textSecondary)
                }
            } else if let weight {
                Text(formatWeightValue(weight))
                    .font(.exerciseValue)
                    .foregroundColor(.accentValue)
                Text(weightUnit.display)
                    .font(.exerciseUnit)
                    .foregroundColor(.textSecondary)
            } else if let unsetPlaceholder {
                Text(unsetPlaceholder)
                    .font(.exerciseValue)
                    .foregroundColor(.accentValue)
            } else {
                Text("chat.exercise.bodyweight")
                    .font(.exerciseValue)
                    .foregroundColor(.accentValue)
            }
        }
    }
}
