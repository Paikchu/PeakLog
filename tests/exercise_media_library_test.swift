import Foundation

// Contract test for the generated exercise library. The library and its media
// are produced by tools/exercise-media/build_library.py + convert_all.sh, so
// this guards the things a regeneration could silently break: the curated ids
// that live workout history references, the enum vocabulary the app decodes,
// and the media files each entry claims to have.

@main
struct ExerciseMediaLibraryTestRunner {
    static func main() {
        shippedLibraryDecodes()
        curatedIdsSurviveRegeneration()
        everyMediaIdHasBothFiles()
        detailKeysReferenceRealExercises()
        curatedNamesAreUnchanged()
        print("exercise_media_library_test passed")
    }

    // MARK: - Paths

    /// tests/ sits directly under the repo root.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static var resources: URL {
        repoRoot.appendingPathComponent("PeakLog/Resources")
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, at url: URL) -> T {
        guard let data = try? Data(contentsOf: url) else {
            fatalError("missing file: \(url.path)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            fatalError("failed to decode \(url.lastPathComponent): \(error)")
        }
    }

    private static var library: ExerciseLibraryFile {
        loadJSON(ExerciseLibraryFile.self, at: resources.appendingPathComponent("exercise_library.json"))
    }

    private static var details: ExerciseDetailFile {
        loadJSON(ExerciseDetailFile.self, at: resources.appendingPathComponent("exercise_details.json"))
    }

    private static var curatedSeed: ExerciseLibraryFile {
        loadJSON(
            ExerciseLibraryFile.self,
            at: repoRoot.appendingPathComponent("tools/exercise-media/curated_seed.json")
        )
    }

    // MARK: - Tests

    /// Decoding at all proves every muscleGroup/equipment/loadType string in the
    /// generated file is a case the Swift enums actually have.
    private static func shippedLibraryDecodes() {
        let exercises = library.exercises
        precondition(exercises.count > 1_000, "expected the full merged library, got \(exercises.count)")

        let ids = Set(exercises.map(\.id))
        precondition(ids.count == exercises.count, "duplicate exercise ids in the library")

        let names = Set(exercises.map(\.nameZH))
        precondition(names.count == exercises.count, "duplicate Chinese names would make the picker ambiguous")

        precondition(details.attribution.contains("Gym visual"), "media attribution must ship with the details file")
    }

    /// Workout history stores `exerciseId`, so dropping or renaming a curated id
    /// would orphan the user's logged sets.
    private static func curatedIdsSurviveRegeneration() {
        let shipped = Set(library.exercises.map(\.id))
        let missing = curatedSeed.exercises.map(\.id).filter { !shipped.contains($0) }
        precondition(missing.isEmpty, "curated ids dropped from the library: \(missing)")
    }

    /// The curated entries carry hand-written Chinese names and tuned
    /// popularity; regeneration may add `mediaId` but must not rewrite them.
    private static func curatedNamesAreUnchanged() {
        let shipped = Dictionary(uniqueKeysWithValues: library.exercises.map { ($0.id, $0) })
        for seed in curatedSeed.exercises {
            guard let current = shipped[seed.id] else { continue }
            precondition(current.nameZH == seed.nameZH,
                         "curated Chinese name changed for \(seed.id): \(seed.nameZH) -> \(current.nameZH)")
            precondition(current.nameEN == seed.nameEN,
                         "curated English name changed for \(seed.id)")
            precondition(current.popularity == seed.popularity,
                         "curated popularity changed for \(seed.id)")
            precondition(current.muscleGroup == seed.muscleGroup,
                         "curated muscle group changed for \(seed.id)")
        }
    }

    /// A `mediaId` with no file on disk renders as a blank tile, which looks
    /// like a bug rather than a missing demonstration.
    private static func everyMediaIdHasBothFiles() {
        let mediaDirectory = resources.appendingPathComponent("ExerciseMedia")
        var missing: [String] = []

        for exercise in library.exercises {
            guard let mediaId = exercise.mediaId else { continue }
            for ext in [ExerciseMedia.animationExtension, ExerciseMedia.thumbnailExtension] {
                let file = mediaDirectory.appendingPathComponent("\(mediaId).\(ext)")
                if !FileManager.default.fileExists(atPath: file.path) {
                    missing.append("\(exercise.id) -> \(mediaId).\(ext)")
                }
            }
        }

        precondition(missing.isEmpty, "exercises reference missing media: \(missing.prefix(10))")
    }

    private static func detailKeysReferenceRealExercises() {
        let ids = Set(library.exercises.map(\.id))
        let orphans = details.details.keys.filter { !ids.contains($0) }
        precondition(orphans.isEmpty, "detail entries with no matching exercise: \(orphans.prefix(10))")

        // Anything with media should also have something to read.
        let withMedia = library.exercises.filter { $0.mediaId != nil }
        let withoutSteps = withMedia.filter { details.details[$0.id] == nil }
        precondition(withoutSteps.isEmpty,
                     "exercises with media but no detail entry: \(withoutSteps.prefix(10).map(\.id))")
    }
}
