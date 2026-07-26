import Combine
import SwiftUI

/// How the app resolves its light/dark appearance.
///
/// `system` is the absence of an override — the app follows the device
/// setting and flips live when the user changes it in iOS Settings or
/// Control Center. `light` / `dark` pin the appearance regardless.
nonisolated enum AppearanceMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var localizedDisplayName: String {
        switch self {
        case .system:
            return String(localized: "profile.preferences.appearance.system")
        case .light:
            return String(localized: "profile.preferences.appearance.light")
        case .dark:
            return String(localized: "profile.preferences.appearance.dark")
        }
    }

    /// `nil` means "no override": SwiftUI keeps following the system.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Owns the app's appearance choice. This is the single source of truth —
/// it is device-local (UserDefaults), resolved synchronously at launch so
/// the first frame is already in the right scheme, and never round-trips
/// through the profile/sync layer.
@MainActor
final class ThemeManager: ObservableObject {
    private static let modeKey = "peaklog.appearanceMode"
    /// Pre-tri-state storage; only read once, to migrate existing installs.
    private static let legacyDarkModeKey = "peaklog.isDarkMode"

    @Published var mode: AppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    /// The device's own scheme, as observed at the app root while `system`
    /// mode leaves it unoverridden. Tracked because sheets need a concrete
    /// value — see `recordSystemColorScheme(_:)`.
    @Published private(set) var systemColorScheme: ColorScheme

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        systemColorScheme = UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light

        if let raw = defaults.string(forKey: Self.modeKey),
           let stored = AppearanceMode(rawValue: raw) {
            mode = stored
        } else if defaults.object(forKey: Self.legacyDarkModeKey) != nil {
            // Existing installs keep exactly the appearance they had; the
            // upgrade must not silently move them onto "follow system".
            mode = defaults.bool(forKey: Self.legacyDarkModeKey) ? .dark : .light
        } else {
            // Fresh installs stay on the dark-first design default.
            mode = .dark
        }
    }

    /// What the app root applies: `nil` in `system` mode, so the window keeps
    /// no override at all and the device setting shows through (and stays
    /// observable — see `recordSystemColorScheme(_:)`).
    var preferredColorScheme: ColorScheme? { mode.preferredColorScheme }

    /// The concrete scheme the app should be rendering right now.
    var resolvedColorScheme: ColorScheme { mode.preferredColorScheme ?? systemColorScheme }

    /// Called from the app root with the scheme it is currently rendering in.
    /// Only meaningful in `system` mode: with an override in place the root
    /// sees the override, not the device setting.
    func recordSystemColorScheme(_ scheme: ColorScheme) {
        guard mode == .system, systemColorScheme != scheme else { return }
        systemColorScheme = scheme
    }
}

// MARK: - Appearance Modifiers

/// Applies the appearance choice to the window and keeps the observed system
/// scheme current. Belongs on the app root, once.
private struct RootAppearance: ViewModifier {
    // Taken as a parameter, not from the environment: at the app root this
    // modifier sits outside `.environmentObject(themeManager)`.
    @ObservedObject var themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(themeManager.preferredColorScheme)
            .onChange(of: colorScheme, initial: true) { _, newValue in
                themeManager.recordSystemColorScheme(newValue)
            }
            // Leaving a pinned mode lifts the override; re-read so "follow
            // system" starts from the device's real scheme even when lifting
            // the override doesn't change what this view renders in.
            .onChange(of: themeManager.mode) { _, _ in
                themeManager.recordSystemColorScheme(colorScheme)
            }
    }
}

private struct SheetAppearance: ViewModifier {
    @EnvironmentObject private var themeManager: ThemeManager

    func body(content: Content) -> some View {
        content.preferredColorScheme(themeManager.resolvedColorScheme)
    }
}

extension View {
    /// Applies the appearance choice to the window. App root only.
    func rootAppearance(_ themeManager: ThemeManager) -> some View {
        modifier(RootAppearance(themeManager: themeManager))
    }

    /// Re-applies the appearance choice to a sheet.
    ///
    /// A sheet is its own presentation: it takes the app root's override when
    /// it is presented but does not follow later changes to it, so without
    /// this a sheet that is open while the choice changes keeps rendering in
    /// the scheme it was born with. It is also handed a *concrete* scheme
    /// rather than `nil` — a presentation keeps the last non-nil scheme it was
    /// given, so `nil` would strand the sheet on the previously pinned mode
    /// instead of releasing it to the system.
    ///
    /// Only needed where the choice can change while the sheet is open, i.e.
    /// the Profile sheet and anything it presents. Sheets elsewhere follow a
    /// device-level change on their own, since `system` mode leaves no
    /// override for SwiftUI to pin them to.
    func appAppearance() -> some View {
        modifier(SheetAppearance())
    }
}
