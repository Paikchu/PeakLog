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

    @State private var decoded: UIImage?
    /// Distinguishes "still decoding" from "decoded and there's nothing" so we
    /// don't flash the fallback glyph before a poster that's about to load.
    @State private var resolved = false

    var body: some View {
        // An in-memory hit resolves synchronously so rows we've already scrolled
        // past never flicker; only a genuine miss defers to the async decode.
        let poster = decoded ?? ExerciseThumbnailCache.shared.cachedImage(for: mediaId)
        let showsGlyph = poster == nil && (mediaId == nil || resolved)
        return Group {
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(1)
            } else if showsGlyph {
                Image(systemName: muscleGroup.symbolName)
                    .appFont(size: size * 0.4, weight: .medium)
                    .foregroundColor(.textMuted)
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(showsGlyph ? Color.workoutPanel : Color.exerciseMediaTile)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .accessibilityHidden(true)
        .task(id: mediaId) {
            resolved = false
            decoded = nil
            if ExerciseThumbnailCache.shared.cachedImage(for: mediaId) == nil {
                decoded = await ExerciseThumbnailCache.shared.image(for: mediaId)
            }
            resolved = true
        }
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

    /// In-memory hit only — safe and instant to call from a SwiftUI body on the
    /// main thread. Returns nil when the poster hasn't been decoded yet.
    func cachedImage(for mediaId: String?) -> UIImage? {
        guard let mediaId else { return nil }
        return cache.object(forKey: mediaId as NSString)
    }

    /// Reads and decodes the poster off the caller's thread on a miss, so a fast
    /// scroll over never-seen rows doesn't block the main thread on disk I/O.
    func image(for mediaId: String?) async -> UIImage? {
        guard let mediaId else { return nil }
        if let hit = cache.object(forKey: mediaId as NSString) { return hit }
        let cache = self.cache
        return await Task.detached(priority: .utility) {
            guard let url = ExerciseMedia.thumbnailURL(for: mediaId),
                  let image = UIImage(contentsOfFile: url.path)
            else {
                return nil
            }
            cache.setObject(image, forKey: mediaId as NSString)
            return image
        }.value
    }
}

// MARK: - Looping Animation

/// Silent, controls-free, endlessly looping demonstration clip. Honours Reduce
/// Motion by falling back to the poster frame.
struct ExerciseAnimationView: View {
    let mediaId: String?
    let muscleGroup: MuscleGroup

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var posterFrame: UIImage?

    private var showsVideo: Bool {
        !reduceMotion && ExerciseMedia.animationURL(for: mediaId) != nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.exerciseMediaTile)

            if showsVideo, let url = ExerciseMedia.animationURL(for: mediaId) {
                LoopingVideoView(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
            } else if let posterFrame {
                Image(uiImage: posterFrame)
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
        .task(id: mediaId) {
            // Only the Reduce Motion / no-video path renders the poster, but it
            // decodes off the main thread either way.
            guard !showsVideo else { return }
            posterFrame = await ExerciseThumbnailCache.shared.image(for: mediaId)
        }
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
