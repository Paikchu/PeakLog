import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func source(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

func section(in source: String, from start: String, to end: String) -> Substring {
    guard
        let startRange = source.range(of: start),
        let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
    else {
        preconditionFailure("Expected source section from \(start) to \(end)")
    }
    return source[startRange.lowerBound..<endRange.lowerBound]
}

let profile = try source("PeakLog/Views/Profile/ProfileScreen.swift")
let stats = try source("PeakLog/Views/Profile/StatCardView.swift")
let volumeParts = try source("PeakLog/Support/ProfileVolumeDisplayParts.swift")
let preferences = try source("PeakLog/Views/Profile/PreferenceRowView.swift")
let avatar = section(
    in: profile,
    from: "private var avatarSection",
    to: "private var goalSection"
)
let header = section(
    in: profile,
    from: "private var header",
    to: "// MARK: - Avatar"
)
let prList = section(
    in: profile,
    from: "private var prSection",
    to: "// MARK: - Header"
)
let goal = section(
    in: profile,
    from: "private var goalSection",
    to: "// MARK: - Stats"
)
let statsSection = section(
    in: profile,
    from: "private var statsSection",
    to: "// MARK: - Preferences"
)
let preferenceList = section(
    in: profile,
    from: "private var preferencesSection",
    to: "// MARK: - Support"
)
let support = section(
    in: profile,
    from: "private var supportSection",
    to: "private var mediaCredit"
)
let mediaCredit = section(
    in: profile,
    from: "private var mediaCredit",
    to: "private func openAppSettings"
)

precondition(
    header.contains(".appFont(size: 32, weight: .bold, relativeTo: .largeTitle)")
        && header.contains(".padding(.horizontal, ProfileLayout.horizontalPadding)")
        && header.contains(".padding(.top, 48)")
        && header.contains(".padding(.bottom, 24)")
        && avatar.contains(".padding(.horizontal, ProfileLayout.horizontalPadding)")
        && avatar.contains(".frame(width: 56, height: 56)")
        && avatar.contains(".appFont(size: 20, weight: .semibold, relativeTo: .title3)")
        && avatar.contains(".appFont(size: 14, relativeTo: .subheadline)")
        && !avatar.contains(".padding(.top")
        && !avatar.contains(".padding(.bottom"),
    "The profile identity must use the coordinated A2 type scale, avatar size, and insets"
)
precondition(
    !avatar.contains(".background(Color.appSurface)")
        && !avatar.contains(".strokeBorder")
        && !avatar.contains(".shadow("),
    "Non-interactive profile information must not use a card or bordered-avatar affordance"
)
precondition(
    stats.contains("struct ProfilePerformanceDashboard")
        && stats.contains("ProfileVolumeDisplayParts(volume)")
        && volumeParts.contains("struct ProfileVolumeDisplayParts")
        && stats.contains("static let horizontalPadding: CGFloat = 20")
        && stats.contains("static let sectionSpacing: CGFloat = 32")
        && stats.contains("static let cardRadius: CGFloat = 18")
        && stats.contains("ProfileMetricRow")
        && stats.contains("Divider()")
        && stats.contains(".background(Color.appSurface)")
        && stats.contains(".cornerRadius(ProfileLayout.cardRadius)")
        && stats.contains(".appFont(size: 32, weight: .bold")
        && stats.contains(".appFont(size: 16, weight: .bold")
        && stats.contains(".frame(minHeight: 144)")
        && !stats.contains(".strokeBorder")
        && !stats.contains(".shadow("),
    "Statistics must use one borderless A2 split dashboard"
)
precondition(
    !stats.contains("Button(")
        && !stats.contains(".onTapGesture")
        && statsSection.contains("ProfilePerformanceDashboard(")
        && !statsSection.contains("StatCardView("),
    "Statistics must remain non-interactive"
)
precondition(
    !prList.contains("SettingsSection(title: \"PRs\")")
        && prList.contains("Text(\"PRs\")")
        && prList.contains("Divider()")
        && !prList.contains(".background(Color.appSurface)")
        && !prList.contains(".strokeBorder")
        && !prList.contains(".shadow("),
    "The non-interactive PR list must use a flat section with row separators and no card affordance"
)
precondition(
    preferences.contains("Button(action: action)")
        && preferences.contains("Image(systemName: \"chevron.right\")")
        && goal.contains("ProfileGoalButton")
        && !goal.contains("SettingsSection(")
        && preferenceList.contains("style: .profile")
        && preferenceList.contains(".padding(.leading, 48)")
        && preferenceList.contains("showsBorder: false")
        && preferenceList.contains("PreferenceNavRow(")
        && preferenceList.contains("PreferenceToggleRow(")
        && support.contains("PreferenceNavRow(")
        && support.contains("style: .profile")
        && support.contains(".padding(.leading, 48)")
        && support.contains("showsBorder: false"),
    "Goal, preference, and support rows must retain their interactive disclosure affordance"
)
precondition(
    mediaCredit.contains("Link(urlString, destination:")
        && mediaCredit.contains(".foregroundColor(.blue)")
        && !mediaCredit.contains(".background(")
        && !mediaCredit.contains(".strokeBorder"),
    "The blue Gym visual URL must be a real link without a card affordance"
)

print("profile_static_affordance_test passed")
