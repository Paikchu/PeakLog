import AVFoundation
import SwiftUI

// MARK: - Exercise Media Views
// The bundled demonstrations are line drawings on a white ground, so they sit
// on their own light tile in both themes rather than bleeding into the dark
// chrome. The tile is dimmed slightly in dark mode so a grid of them doesn't
// glare.

private extension Color {
    static let exerciseMediaTile = Color(uiColor: UIColor(dynamicProvider: { tc in
        tc.userInterfaceStyle == .dark ? UIColor(appHex: "#E4E2DE") : UIColor(appHex: "#FFFFFF")
    }))
}

// MARK: - Thumbnail

/// Static poster frame for list rows. Falls back to a muscle-group glyph when
/// the exercise has no bundled media (user-created exercises, and the few seed
/// entries with no matching demonstration).
struct ExerciseThumbnailView: View {
    let mediaId: String?
    let muscleGroup: MuscleGroup
    var size: CGFloat = 44

    var body: some View {
        let poster = ExerciseThumbnailCache.shared.image(for: mediaId)
        return Group {
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(1)
            } else {
                Image(systemName: muscleGroup.symbolName)
                    .appFont(size: size * 0.4, weight: .medium)
                    .foregroundColor(.textMuted)
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(poster == nil ? Color.workoutPanel : Color.exerciseMediaTile)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .accessibilityHidden(true)
    }
}

/// Decoding a 180×180 JPEG per row on every scroll tick is wasteful when the
/// picker revisits the same rows constantly, so decoded posters are held in an
/// NSCache that the system can evict under pressure.
final class ExerciseThumbnailCache: @unchecked Sendable {
    static let shared = ExerciseThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 240
    }

    func image(for mediaId: String?) -> UIImage? {
        guard let mediaId else { return nil }
        if let hit = cache.object(forKey: mediaId as NSString) { return hit }
        guard let url = ExerciseMedia.thumbnailURL(for: mediaId),
              let image = UIImage(contentsOfFile: url.path)
        else {
            return nil
        }
        cache.setObject(image, forKey: mediaId as NSString)
        return image
    }
}

// MARK: - Looping Animation

/// Silent, controls-free, endlessly looping demonstration clip. Honours Reduce
/// Motion by falling back to the poster frame.
struct ExerciseAnimationView: View {
    let mediaId: String?
    let muscleGroup: MuscleGroup

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.exerciseMediaTile)

            if let url = ExerciseMedia.animationURL(for: mediaId), !reduceMotion {
                LoopingVideoView(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
            } else if let image = ExerciseThumbnailCache.shared.image(for: mediaId) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: muscleGroup.symbolName)
                    .appFont(size: 48, weight: .light)
                    .foregroundColor(.textMuted)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(Text("exercise_detail.animation_accessibility"))
    }
}

private struct LoopingVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.play(url: url)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.play(url: url)
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: ()) {
        uiView.stop()
    }
}

/// AVPlayerLooper needs the queue player and the looper to outlive the call
/// that starts playback, so both are held by the view that owns the layer.
final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    func play(url: URL) {
        guard currentURL != url else {
            player?.play()
            return
        }
        stop()
        currentURL = url

        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        // Without this the clip stutters when the app is also driving a Live
        // Activity or the device is in Low Power Mode.
        queuePlayer.automaticallyWaitsToMinimizeStalling = false

        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        player = queuePlayer
        playerLayer.player = queuePlayer
        playerLayer.videoGravity = .resizeAspect
        queuePlayer.play()
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        playerLayer.player = nil
        currentURL = nil
    }
}

// MARK: - Muscle Group Glyphs

extension MuscleGroup {
    /// Placeholder glyph for exercises without bundled media.
    var symbolName: String {
        switch self {
        case .chest: return "figure.strengthtraining.traditional"
        case .back: return "figure.rower"
        case .legs: return "figure.step.training"
        case .shoulders: return "figure.arms.open"
        case .arms: return "dumbbell"
        case .core: return "figure.core.training"
        case .fullBody: return "figure.mixed.cardio"
        }
    }
}
