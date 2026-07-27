import Foundation

nonisolated struct ProfileVolumeDisplayParts: Equatable, Sendable {
    let value: String
    let unit: String

    init(_ display: String) {
        for unit in ["k lbs", "lbs", "kg", "t"] where display.hasSuffix(unit) {
            value = display.dropLast(unit.count).trimmingCharacters(in: .whitespaces)
            self.unit = unit
            return
        }

        value = display
        unit = ""
    }
}
