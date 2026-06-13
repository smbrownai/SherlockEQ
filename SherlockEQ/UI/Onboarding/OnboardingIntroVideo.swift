import AVFoundation
import AVKit
import SwiftUI

/// One-shot intro video for the onboarding welcome screen.
///
/// Plays once on appear and **stops on its last frame** — no loop, no
/// playback controls (`actionAtItemEnd = .pause` holds the final frame).
/// Sized to the available width at the video's own aspect ratio.
///
/// The video is a bundled resource looked up by bare name (the app bundle is
/// flattened — see `help-docs-bundle-flattened.md`), so the file can live
/// anywhere under the synchronized `SherlockEQ/` group; the convention is
/// `SherlockEQ/Resources/onboarding-intro.{mp4,mov,m4v}`. If no such resource
/// is bundled, the whole view collapses to nothing, so onboarding looks
/// exactly as it did before the video was added — the welcome screen degrades
/// gracefully on builds that ship without the asset.
struct OnboardingIntroVideo: View {

    /// Bare resource name (no extension, no path — bundle is flattened).
    static let resourceName = "onboarding-intro"
    /// Container extensions tried in order.
    private static let extensions = ["mp4", "mov", "m4v"]

    /// Aspect-ratio fallback used until the real ratio loads (and if the
    /// asset can't report one). 16:9 is the most common capture ratio.
    private static let fallbackAspect: CGFloat = 16.0 / 9.0

    /// Beat to hold on the first frame before playback begins, so the welcome
    /// screen settles before the motion starts.
    private static let startDelay: TimeInterval = 0.5

    @State private var aspect: CGFloat?

    private static func resourceURL() -> URL? {
        for ext in extensions {
            if let url = Bundle.main.url(forResource: resourceName, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    var body: some View {
        if let url = Self.resourceURL() {
            // Full-bleed hero: full window width at the video's own aspect
            // ratio, no corner rounding or border, clipped to a hard edge.
            IntroPlayerView(url: url, startDelay: Self.startDelay)
                .aspectRatio(aspect ?? Self.fallbackAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .task { aspect = await Self.loadAspectRatio(url) }
                // Decorative — the welcome cards below carry the actual message.
                .accessibilityHidden(true)
        }
    }

    /// Read the video track's display aspect ratio (natural size with the
    /// preferred transform applied, so rotated captures aren't shown sideways).
    private static func loadAspectRatio(_ url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)
        guard
            let track = try? await asset.loadTracks(withMediaType: .video).first,
            let naturalSize = try? await track.load(.naturalSize),
            let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let resolved = naturalSize.applying(transform)
        let w = abs(resolved.width), h = abs(resolved.height)
        guard w > 0, h > 0 else { return nil }
        return w / h
    }
}

/// Thin AppKit bridge: an `AVPlayerView` with no chrome that holds the first
/// frame for `startDelay` seconds, plays through once, and freezes on the
/// final frame.
private struct IntroPlayerView: NSViewRepresentable {
    let url: URL
    let startDelay: TimeInterval

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill   // fill edge-to-edge, never letterbox
        view.allowsPictureInPicturePlayback = false

        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause   // hold the last frame; do not loop
        player.isMuted = false            // it's a deliberate intro — let it speak
        view.player = player

        // Hold on the first frame, then play once. Cancellable so advancing
        // past the welcome screen before the beat elapses can't leave a
        // detached player playing audio in the background.
        let start = DispatchWorkItem { player.play() }
        context.coordinator.pendingStart = start
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay, execute: start)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.pendingStart?.cancel()
        nsView.player?.pause()
        nsView.player = nil
    }

    final class Coordinator {
        var pendingStart: DispatchWorkItem?
    }
}
