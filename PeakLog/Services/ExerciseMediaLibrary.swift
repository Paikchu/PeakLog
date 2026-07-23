import Foundation

// MARK: - Exercise Media
// Demonstration media ships in the bundle as a pair per exercise, keyed by
// `ExerciseDefinition.mediaId`: a 180×180 JPEG poster for list rows and a
// looping HEVC clip for the detail screen. The clips are transcoded from the
// source GIFs by tools/exercise-media/convert_all.sh — same frame timing, about
// an eighth of the bytes.
//
// Media is © Gym visual (https://gymvisual.com/); the attribution shipped in
// exercise_details.json has to stay visible wherever the media is shown.

nonisolated enum ExerciseMedia {
    static let animationExtension = "mov"
    static let thumbnailExtension = "jpg"

    static func animationURL(for mediaId: String?, bundle: Bundle = .main) -> URL? {
        guard let mediaId else { return nil }
        return bundle.url(forResource: mediaId, withExtension: animationExtension)
    }

    static func thumbnailURL(for mediaId: String?, bundle: Bundle = .main) -> URL? {
        guard let mediaId else { return nil }
        return bundle.url(forResource: mediaId, withExtension: thumbnailExtension)
    }
}

// MARK: - Exercise Detail

nonisolated struct ExerciseDetail: Codable, Equatable, Sendable {
    let mediaId: String
    /// Primary muscle worked, as the source dataset labels it ("pectorals").
    let target: String
    let secondaryMuscles: [String]
    let stepsEN: [String]
    let stepsZH: [String]

    func steps(for language: AppLanguage) -> [String] {
        switch language {
        case .english:
            return stepsEN.isEmpty ? stepsZH : stepsEN
        case .simplifiedChinese:
            return stepsZH.isEmpty ? stepsEN : stepsZH
        }
    }
}

nonisolated struct ExerciseDetailFile: Codable, Sendable {
    let version: Int
    let attribution: String
    let details: [String: ExerciseDetail]
}

// MARK: - Detail Library
// Step-by-step instructions for ~1,300 exercises are an order of magnitude
// larger than the search index, and only ever needed one exercise at a time on
// the detail screen. So they live in their own file, parsed on first use and
// then held for the process lifetime.

actor ExerciseDetailLibrary {
    static let shared = ExerciseDetailLibrary()

    private let bundle: Bundle
    private var loaded: ExerciseDetailFile?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func detail(for exerciseId: String) -> ExerciseDetail? {
        file()?.details[exerciseId]
    }

    func attribution() -> String? {
        file()?.attribution
    }

    private func file() -> ExerciseDetailFile? {
        if let loaded { return loaded }
        guard let url = bundle.url(forResource: "exercise_details", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ExerciseDetailFile.self, from: data)
        else {
            return nil
        }
        loaded = decoded
        return decoded
    }
}
