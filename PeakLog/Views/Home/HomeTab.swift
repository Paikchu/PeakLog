import SwiftUI

enum HomeTab: String, Hashable {
    case calendar
    case plan
    case settings

    var title: String {
        switch self {
        case .calendar:
            return String(localized: "home_dock.calendar")
        case .plan:
            return String(localized: "home_dock.plan")
        case .settings:
            return String(localized: "home_dock.settings")
        }
    }

    var symbolName: String {
        switch self {
        case .calendar:
            return "calendar"
        case .plan:
            return "figure.strengthtraining.traditional"
        case .settings:
            return "gearshape.fill"
        }
    }
}
