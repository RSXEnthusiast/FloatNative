import SwiftUI

/// Renders the currently-active WebVTT cue(s) over the AVPlayer surface.
/// Observes `AVPlayerManager.currentTime` and `captionCues` — when the user
/// toggles `captionsEnabled` we hide the overlay without touching the cues.
///
/// We didn't fight AVPlayer's HLS parser any longer (synthetic master kept
/// hitting CoreMediaErrorDomain -12881); rendering ourselves is what the
/// industry calls "side-loaded subtitles" and it's bulletproof.
struct CaptionsOverlay: View {
    @ObservedObject var playerManager: AVPlayerManager

    private var activeText: String {
        guard playerManager.captionsEnabled, !playerManager.captionCues.isEmpty else { return "" }
        let active = VTTCueParser.activeCues(playerManager.captionCues, at: playerManager.currentTime)
        return active.map { stripVTTTags($0.payload) }.joined(separator: "\n")
    }

    var body: some View {
        // Bigger text on tvOS (TVs are far from the viewer) and a tighter
        // bottom inset so the caption sits just above where the transport bar
        // surfaces. AVPlayerViewController shrinks `contentOverlayView`
        // upward when its controls show, so a small inset keeps the caption
        // close to the chrome instead of stranded mid-screen.
        #if os(tvOS)
        let fontSize: CGFloat = 32
        let bottomInset: CGFloat = 8
        let bgPaddingH: CGFloat = 16
        let bgPaddingV: CGFloat = 8
        let edgeInset: CGFloat = 32
        #else
        let fontSize: CGFloat = 18
        let bottomInset: CGFloat = 32
        let bgPaddingH: CGFloat = 12
        let bgPaddingV: CGFloat = 6
        let edgeInset: CGFloat = 24
        #endif

        return VStack {
            Spacer()
            if !activeText.isEmpty {
                Text(activeText)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, bgPaddingH)
                    .padding(.vertical, bgPaddingV)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding(.horizontal, edgeInset)
                    .padding(.bottom, bottomInset)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)  // never intercept taps meant for the player chrome
        .animation(.easeInOut(duration: 0.15), value: activeText)
    }

    /// Strip the most common WebVTT inline tags so plain Text renders cleanly.
    /// Floatplane's auto-generated captions only use `<c>` colour and `<i>`
    /// emphasis tags so far; the regex covers any single-letter tag with
    /// optional class settings.
    private func stripVTTTags(_ raw: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return raw }
        let ns = raw as NSString
        return regex.stringByReplacingMatches(
            in: raw,
            options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
    }
}
