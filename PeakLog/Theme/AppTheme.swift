import SwiftUI

// MARK: - Color Tokens (Adaptive — auto-switches with preferredColorScheme)
extension Color {
    // Backgrounds
    static let appBackground = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#0F0F14") : UIColor(appHex: "#f8f8fa")
    }))
    static let appSurface = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#1A1A24") : UIColor(appHex: "#FFFFFF")
    }))
    static let appCard = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#252536") : UIColor(appHex: "#FFFFFF")
    }))
    static let appSeparator = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#2A2A3A") : UIColor(appHex: "#f3f4f6")
    }))

    // Bubbles
    static let userBubble = Color(hex: "#7C7FBF")

    // Accents (same in both themes)
    static let accentPurple = Color(hex: "#4F39F6")
    static let accentBorder = Color(hex: "#6366F1")
    static let accentRed = Color(hex: "#FB2C36")
    static let accentValue = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#A3B3FF") : UIColor(appHex: "#4F39F6")
    }))

    // Text
    static let textPrimary = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#F3F4F6") : UIColor(appHex: "#101828")
    }))
    static let textSecondary = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#99A1AF") : UIColor(appHex: "#1e2939")
    }))
    static let textMuted = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#6A7282") : UIColor(appHex: "#99a1af")
    }))
    static let textDarkMuted = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#4A5565") : UIColor(appHex: "#9CA3AF")
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
        colors: [Color(hex: "#4F39F6"), Color(hex: "#6366F1")],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Font Tokens
extension Font {
    // Headers
    static let headerTitle = Font.system(size: 17, weight: .semibold)
    static let screenTitle = Font.system(size: 17, weight: .semibold)

    // Body
    static let chatBody = Font.system(size: 14.5, weight: .regular)
    static let chatBodyMedium = Font.system(size: 14.5, weight: .medium)

    // Exercise
    static let exerciseName = Font.system(size: 14, weight: .bold)
    static let exerciseValue = Font.system(size: 15, weight: .bold)
    static let exerciseUnit = Font.system(size: 11, weight: .medium)

    // Labels
    static let setIndex = Font.system(size: 12, weight: .medium)
    static let dateLabel = Font.system(size: 12, weight: .medium)
    static let recordHeader = Font.system(size: 13, weight: .semibold)
    static let deleteLabel = Font.system(size: 10, weight: .medium)

    // Stats
    static let statValue = Font.system(size: 16, weight: .bold)
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
