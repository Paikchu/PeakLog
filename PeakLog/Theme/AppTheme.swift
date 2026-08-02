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
    // `@MainActor` explicitly: `Color.accentValue` (and every other token in
    // this file) is main-actor isolated under the module's default isolation,
    // but a `static let` on an imported `Sendable` type is inferred
    // `nonisolated`, so the initializer would be reading main-actor state from
    // a nonisolated context — an error in the Swift 6 language mode. Every
    // call site is a SwiftUI view body, which is already on the main actor.
    @MainActor
    static let accentGradient = LinearGradient(
        colors: [Color.accentValue, Color(hex: "#F97316")],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Font Tokens
// Numeric styles use the rounded design so weights/reps read like gym plates.
// Sizes are the design reference at the default (Large) content size; rendering
// goes through `.appFont(...)`, which scales them with Dynamic Type. `relativeTo`
// picks the system text style whose scaling curve the token follows.
struct AppFont {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    var relativeTo: Font.TextStyle = .body

    // Headers
    static let headerTitle = AppFont(size: 17, weight: .semibold, relativeTo: .headline)
    static let screenTitle = AppFont(size: 17, weight: .semibold, relativeTo: .headline)

    // Body
    static let chatBody = AppFont(size: 14.5, relativeTo: .subheadline)
    static let chatBodyMedium = AppFont(size: 14.5, weight: .medium, relativeTo: .subheadline)

    // Exercise
    static let exerciseName = AppFont(size: 14, weight: .bold, relativeTo: .subheadline)
    static let exerciseValue = AppFont(size: 15, weight: .bold, design: .rounded, relativeTo: .subheadline)
    static let exerciseUnit = AppFont(size: 11, weight: .medium, design: .rounded, relativeTo: .caption2)

    // Labels
    static let setIndex = AppFont(size: 12, weight: .medium, design: .rounded, relativeTo: .caption)
    static let dateLabel = AppFont(size: 12, weight: .medium, relativeTo: .caption)
    static let recordHeader = AppFont(size: 13, weight: .semibold, relativeTo: .footnote)

    // Stats
    static let statValue = AppFont(size: 16, weight: .bold, design: .rounded, relativeTo: .callout)
    static let statLabel = AppFont(size: 11, weight: .medium, relativeTo: .caption2)

    // Settings
    static let settingTitle = AppFont(size: 15, weight: .medium, relativeTo: .subheadline)
    static let settingValue = AppFont(size: 13, relativeTo: .footnote)
}

private struct ScaledAppFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(_ token: AppFont) {
        _size = ScaledMetric(wrappedValue: token.size, relativeTo: token.relativeTo)
        weight = token.weight
        design = token.design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// Applies a theme font token, scaled with the user's Dynamic Type setting.
    func appFont(_ token: AppFont) -> some View {
        modifier(ScaledAppFont(token))
    }

    /// Applies a one-off font that scales with Dynamic Type, replacing fixed
    /// `Font.system(size:)` usages.
    func appFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> some View {
        modifier(ScaledAppFont(AppFont(size: size, weight: weight, design: design, relativeTo: textStyle)))
    }
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
