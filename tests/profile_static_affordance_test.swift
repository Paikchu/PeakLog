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

precondition(
    header.contains(".padding(.top, 16)") && avatar.contains(".padding(.top, 8)"),
    "The page title must gain 16pt of top space without enlarging the profile information gap"
)
precondition(
    !avatar.contains(".background(Color.appSurface)")
        && !avatar.contains(".strokeBorder")
        && !avatar.contains(".shadow("),
    "Non-interactive profile information must not use a card or bordered-avatar affordance"
)
precondition(
    !stats.contains(".background(Color.appSurface)")
        && !stats.contains(".cornerRadius(AppRadius.xl)")
        && !stats.contains(".strokeBorder")
        && !stats.contains(".shadow("),
    "Non-interactive statistics must not use an outer card affordance"
)
precondition(
    !stats.contains("Button(") && !stats.contains(".onTapGesture"),
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
        && goal.contains("PreferenceNavRow(")
        && preferenceList.contains("PreferenceNavRow(")
        && preferenceList.contains("PreferenceToggleRow(")
        && support.contains("PreferenceNavRow("),
    "Goal, preference, and support rows must retain their interactive disclosure affordance"
)

print("profile_static_affordance_test passed")
