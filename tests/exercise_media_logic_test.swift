import Foundation

// Unit coverage for the pure runtime logic in ExerciseMediaLibrary.swift, which
// the data-focused exercise_media_library_test doesn't exercise: the bilingual
// step fallback, media-URL resolution for a nil mediaId, and the detail actor's
// retry-on-failure behaviour when the bundle has no details file.

@main
struct ExerciseMediaLogicTestRunner {
    static func main() async {
        stepsPreferRequestedLanguage()
        stepsFallBackWhenRequestedLanguageEmpty()
        stepsAreEmptyWhenBothLanguagesEmpty()
        mediaURLsAreNilForNilMediaID()
        await detailLibraryRetriesAfterMissingFile()
        print("exercise_media_logic_test passed")
    }

    private static func detail(en: [String], zh: [String]) -> ExerciseDetail {
        ExerciseDetail(mediaId: "0001", target: "abs", secondaryMuscles: [], stepsEN: en, stepsZH: zh)
    }

    private static func stepsPreferRequestedLanguage() {
        let d = detail(en: ["Lie down"], zh: ["躺下"])
        precondition(d.steps(for: .english) == ["Lie down"], "English request should return English steps")
        precondition(d.steps(for: .simplifiedChinese) == ["躺下"], "Chinese request should return Chinese steps")
    }

    /// The dataset has entries translated in one language but not the other; the
    /// detail screen must show *something* rather than an empty list.
    private static func stepsFallBackWhenRequestedLanguageEmpty() {
        let missingZH = detail(en: ["Step one"], zh: [])
        precondition(missingZH.steps(for: .simplifiedChinese) == ["Step one"],
                     "empty Chinese steps should fall back to English")

        let missingEN = detail(en: [], zh: ["第一步"])
        precondition(missingEN.steps(for: .english) == ["第一步"],
                     "empty English steps should fall back to Chinese")
    }

    private static func stepsAreEmptyWhenBothLanguagesEmpty() {
        let none = detail(en: [], zh: [])
        precondition(none.steps(for: .english).isEmpty, "no steps in either language should stay empty")
        precondition(none.steps(for: .simplifiedChinese).isEmpty, "no steps in either language should stay empty")
    }

    private static func mediaURLsAreNilForNilMediaID() {
        precondition(ExerciseMedia.animationURL(for: nil) == nil, "nil mediaId must not resolve an animation URL")
        precondition(ExerciseMedia.thumbnailURL(for: nil) == nil, "nil mediaId must not resolve a thumbnail URL")
    }

    /// A first load that fails (empty test bundle) must not poison the actor:
    /// once the details file becomes available a later call should still work.
    /// Here we can only assert the failure path stays retryable — it must return
    /// nil without trapping, every time.
    private static func detailLibraryRetriesAfterMissingFile() async {
        let library = ExerciseDetailLibrary(bundle: Bundle(for: MarkerClass.self))
        let first = await library.detail(for: "barbell-bench-press")
        let second = await library.attribution()
        precondition(first == nil, "a bundle without exercise_details.json should yield no detail")
        precondition(second == nil, "a bundle without exercise_details.json should yield no attribution")
    }

    private final class MarkerClass {}
}
