import Foundation

nonisolated enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var localeIdentifier: String {
        switch self {
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }

    var nativeDisplayName: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }

    static func resolve(_ value: String?) -> AppLanguage? {
        guard let value else { return nil }
        let normalized = value.lowercased()

        if normalized.hasPrefix("zh") {
            return .simplifiedChinese
        }

        if normalized.hasPrefix("en") {
            return .english
        }

        return nil
    }

    static func bestMatch(for identifiers: [String]) -> AppLanguage {
        for identifier in identifiers {
            if let match = resolve(identifier) {
                return match
            }
        }

        return .english
    }

}
