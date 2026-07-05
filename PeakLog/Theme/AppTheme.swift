import SwiftUI

// MARK: - Graphite Theme
// Carbon-dark neutrals with a single amber accent. Numbers are the hero;
// chrome stays out of the way. All tokens adapt to light/dark automatically.

// MARK: - Color Tokens (Adaptive — auto-switches with preferredColorScheme)
extension Color {
    // Backgrounds
    static let appBackground = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#0B0B0D") : UIColor(appHex: "#F5F5F4")
    }))
    static let appSurface = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#17171A") : UIColor(appHex: "#FFFFFF")
    }))
    static let appCard = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#1D1D21") : UIColor(appHex: "#FFFFFF")
    }))
    static let appSeparator = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#29292E") : UIColor(appHex: "#E7E5E4")
    }))
    static let workoutShell = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#202024") : UIColor(appHex: "#FAFAF9")
    }))
    static let workoutPanel = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#26262B") : UIColor(appHex: "#F0EFED")
    }))
    static let workoutPanelStrong = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#2E2E34") : UIColor(appHex: "#E7E5E1")
    }))
    static let workoutIndexFill = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#2E2E34") : UIColor(appHex: "#ECEAE7")
    }))

    // Bubbles
    static let userBubble = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#2E2E33") : UIColor(appHex: "#292524")
    }))

    // Accents
    static let accentPrimary = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#F59E0B") : UIColor(appHex: "#D97706")
    }))
    static let accentBorder = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#8A8A93") : UIColor(appHex: "#A8A29E")
    }))
    static let accentRed = Color(hex: "#EF4444")
    static let accentValue = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#FBBF24") : UIColor(appHex: "#B45309")
    }))

    // Text
    static let textPrimary = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#F5F5F4") : UIColor(appHex: "#1C1917")
    }))
    static let textSecondary = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#A8A29E") : UIColor(appHex: "#57534E")
    }))
    static let textMuted = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#737373") : UIColor(appHex: "#A8A29E")
    }))
    static let textDarkMuted = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#47474E") : UIColor(appHex: "#C7C2BC")
    }))
}

// MARK: - Hex Initializers
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

extension UIColor {
    convenience init(appHex hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: (r, g, b) = (0, 0, 0)
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

// MARK: - Gradient
extension LinearGradient {
    static let accentGradient = LinearGradient(
        colors: [Color.accentValue, Color(hex: "#F97316")],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Font Tokens
// Numeric styles use the rounded design so weights/reps read like gym plates.
extension Font {
    // Headers
    static let headerTitle = Font.system(size: 17, weight: .semibold)
    static let screenTitle = Font.system(size: 17, weight: .semibold)

    // Body
    static let chatBody = Font.system(size: 14.5, weight: .regular)
    static let chatBodyMedium = Font.system(size: 14.5, weight: .medium)

    // Exercise
    static let exerciseName = Font.system(size: 14, weight: .bold)
    static let exerciseValue = Font.system(size: 15, weight: .bold, design: .rounded)
    static let exerciseUnit = Font.system(size: 11, weight: .medium, design: .rounded)

    // Labels
    static let setIndex = Font.system(size: 12, weight: .medium, design: .rounded)
    static let dateLabel = Font.system(size: 12, weight: .medium)
    static let recordHeader = Font.system(size: 13, weight: .semibold)
    static let deleteLabel = Font.system(size: 10, weight: .medium)

    // Stats
    static let statValue = Font.system(size: 16, weight: .bold, design: .rounded)
    static let statLabel = Font.system(size: 11, weight: .medium)

    // Settings
    static let settingTitle = Font.system(size: 15, weight: .medium)
    static let settingValue = Font.system(size: 13, weight: .regular)
}

// MARK: - Spacing & Corner Radius
enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum AppRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 14
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let full: CGFloat = 999
}
