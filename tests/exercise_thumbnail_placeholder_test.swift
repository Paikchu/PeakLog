import Foundation

// Contract guard for ExerciseThumbnailView's loading branch.
//
// The poster decode is kicked off by a `.task` attached *after* the content
// `Group`. If that Group can evaluate to nothing — an `if`/`else if` chain with
// no `else` — SwiftUI collapses the whole view to a nil view and drops every
// modifier hanging off it, `.task` included. The decode then never starts, the
// state never leaves "still loading", and the row stays permanently blank: no
// poster, no fallback glyph, not even the 44pt tile. That was the bug where
// every exercise with a mediaId lost its demonstration image in the picker.
//
// So the loading branch has to render something concrete.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let media = try String(
    contentsOf: root.appendingPathComponent("PeakLog/Views/Shared/ExerciseMediaViews.swift"),
    encoding: .utf8
)

guard let thumbnailStart = media.range(of: "struct ExerciseThumbnailView: View {"),
      let thumbnailEnd = media.range(of: "final class ExerciseThumbnailCache")
else {
    fatalError("ExerciseThumbnailView / ExerciseThumbnailCache no longer found in ExerciseMediaViews.swift")
}
let thumbnail = String(media[thumbnailStart.upperBound..<thumbnailEnd.lowerBound])

precondition(
    thumbnail.contains(".task(id: mediaId)"),
    "Thumbnail still has to decode its poster off the main thread via .task"
)
precondition(
    thumbnail.contains("} else {"),
    "Thumbnail's content Group needs an else branch — an empty Group is a nil view and drops the .task that loads the poster"
)
precondition(
    thumbnail.contains("Color.clear"),
    "The loading branch must render a concrete placeholder so the tile keeps its frame while decoding"
)

// The detail-screen animation reserves its frame with an always-present tile
// behind the ZStack, so it can't regress the same way — but it must keep an
// else branch too, or a missing clip would render nothing at all.
guard let animationStart = media.range(of: "struct ExerciseAnimationView: View {"),
      let animationEnd = media.range(of: "private struct LoopingVideoView")
else {
    fatalError("ExerciseAnimationView / LoopingVideoView no longer found in ExerciseMediaViews.swift")
}
let animation = String(media[animationStart.upperBound..<animationEnd.lowerBound])

precondition(
    animation.contains("} else {"),
    "Animation view needs a fallback branch for exercises with no bundled clip"
)

print("exercise_thumbnail_placeholder_test passed")
