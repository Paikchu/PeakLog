import Foundation

// MARK: - Exercise Library Models
// The bundled seed library plus user-created custom exercises share this
// definition. IDs are stable slugs ("barbell-bench-press") so records can
// reference an exercise across devices and future backend sync.

nonisolated enum MuscleGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case chest
    case back
    case legs
    case shoulders
    case arms
    case core
    case fullBody = "full_body"

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .chest: return String(localized: "muscle_group.chest")
        case .back: return String(localized: "muscle_group.back")
        case .legs: return String(localized: "muscle_group.legs")
        case .shoulders: return String(localized: "muscle_group.shoulders")
        case .arms: return String(localized: "muscle_group.arms")
        case .core: return String(localized: "muscle_group.core")
        case .fullBody: return String(localized: "muscle_group.full_body")
        }
    }
}

nonisolated enum Equipment: String, Codable, CaseIterable, Identifiable, Sendable {
    case barbell
    case dumbbell
    case machine
    case cable
    case bodyweight
    case kettlebell
    case other

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .barbell: return String(localized: "equipment.barbell")
        case .dumbbell: return String(localized: "equipment.dumbbell")
        case .machine: return String(localized: "equipment.machine")
        case .cable: return String(localized: "equipment.cable")
        case .bodyweight: return String(localized: "equipment.bodyweight")
        case .kettlebell: return String(localized: "equipment.kettlebell")
        case .other: return String(localized: "equipment.other")
        }
    }
}

nonisolated struct ExerciseDefinition: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var nameEN: String
    var nameZH: String
    var aliases: [String]
    var muscleGroup: MuscleGroup
    var equipment: Equipment
    var loadType: ExerciseLoadType
    var popularity: Int
    var isCustom: Bool
    /// Key into the bundled animation/thumbnail pair, when one exists. Nil for
    /// user-created exercises and for the handful of seed entries the media
    /// library has no matching demonstration for.
    var mediaId: String?

    init(
        id: String,
        nameEN: String,
        nameZH: String,
        aliases: [String] = [],
        muscleGroup: MuscleGroup,
        equipment: Equipment,
        loadType: ExerciseLoadType,
        popularity: Int = 50,
        isCustom: Bool = false,
        mediaId: String? = nil
    ) {
        self.id = id
        self.nameEN = nameEN
        self.nameZH = nameZH
        self.aliases = aliases
        self.muscleGroup = muscleGroup
        self.equipment = equipment
        self.loadType = loadType
        self.popularity = popularity
        self.isCustom = isCustom
        self.mediaId = mediaId
    }

    // Lenient decode so the seed JSON can omit aliases/popularity/isCustom/mediaId.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        nameEN = try container.decode(String.self, forKey: .nameEN)
        nameZH = try container.decode(String.self, forKey: .nameZH)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        muscleGroup = try container.decode(MuscleGroup.self, forKey: .muscleGroup)
        equipment = try container.decode(Equipment.self, forKey: .equipment)
        loadType = try container.decode(ExerciseLoadType.self, forKey: .loadType)
        popularity = try container.decodeIfPresent(Int.self, forKey: .popularity) ?? 50
        isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        mediaId = try container.decodeIfPresent(String.self, forKey: .mediaId)
    }

    func displayName(for language: AppLanguage) -> String {
        switch language {
        case .english: return nameEN
        case .simplifiedChinese: return nameZH
        }
    }

    /// Case- and whitespace-insensitive match against both names and aliases,
    /// independent of the current UI language.
    func matches(query: String) -> Bool {
        let normalized = Self.normalize(query)
        guard !normalized.isEmpty else { return true }
        if Self.normalize(nameEN).contains(normalized) { return true }
        if Self.normalize(nameZH).contains(normalized) { return true }
        return aliases.contains { Self.normalize($0).contains(normalized) }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && $0 != "-" }
    }
}

// MARK: - Seed Library File

nonisolated struct ExerciseLibraryFile: Codable, Sendable {
    let version: Int
    let exercises: [ExerciseDefinition]
}
